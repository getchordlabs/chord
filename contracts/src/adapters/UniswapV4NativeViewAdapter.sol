// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

// Minimal V4 interfaces (same shape as UniswapV4Adapter — kept local so this file is self-contained
// for Sourcify verification).
interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    // Returns BalanceDelta: upper 128 bits = amount0, lower 128 bits = amount1
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 balanceDelta);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title UniswapV4NativeViewAdapter
/// @notice Uniswap V4 adapter for chains whose gas token has NO wrapper but an ERC-20 *view*
///         predeploy at a different decimal scale — Arc (5042): native USDC is 18-dec, the ERC-20
///         predeploy `0x3600…0000` is 6-dec and `balanceOf(a) == a.balance / 1e12` (measured
///         2026-09-16 on the PoolManager and a launchpad hook: equal to the unit).
/// @dev Same PoolManager unlock/swap/settle/take flow as UniswapV4Adapter, with the wrap/unwrap
///      replaced by a pure decimal scale:
///        · the router pushes `amountIn` of NATIVE_VIEW (6-dec) to this adapter, which by the
///          predeploy's semantics IS `amountIn * SCALE` wei of native balance — so a native-in leg
///          settles `amountIn * SCALE` by value, no deposit() needed;
///        · a native-out leg takes the raw 18-dec amount to this adapter and forwards
///          `raw / SCALE` through the predeploy's `transfer` (which moves native under the hood).
///          The sub-unit remainder (< SCALE wei = < 1e-6 USDC) stays here; it is dust by construction.
///      extraData = abi.encode(PoolKey) INCLUDING the pool's real `hooks` — the poolId is the hash
///      of the full key, so a zeroed hook names a pool that does not exist (revert). Launchpad pools
///      on Arc (minara.ai, lift.fun, …) are hooked with fee = 0; the hook charges the fee, the
///      engine quotes them through the V4 Quoter which runs the hook.
///
///      H1 hardening carried over: `onlyRouter` entrypoint gate + the PoolKey is BOUND to the route
///      (its two currencies must be exactly (tokenIn, tokenOut) with native ↔ NATIVE_VIEW), so a
///      caller cannot settle the router's input into an unrelated pool.
contract UniswapV4NativeViewAdapter is IAdapter, BaseAdapter {
    IPoolManager public immutable POOL_MANAGER;
    /// @notice ERC-20 view of the gas token (Arc: USDC predeploy 0x3600…0000, 6 dec).
    address public immutable NATIVE_VIEW;
    /// @notice 10 ** (nativeDecimals − viewDecimals): raw native wei per NATIVE_VIEW unit (Arc: 1e12).
    uint256 public immutable SCALE;

    // sqrt(1.0001^MIN_TICK) * 2^96 — minimum price limit for zeroForOne
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    // sqrt(1.0001^MAX_TICK) * 2^96 — maximum price limit for oneForZero
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    struct CallbackData {
        PoolKey key;
        /// @dev In the POOL's units: raw native wei when the input currency is address(0).
        uint256 amountSpecified;
        bool zeroForOne;
        address recipient;
    }

    error NotPoolManager();
    /// @notice The PoolKey's currencies are not the route's (tokenIn, tokenOut).
    error KeyNotBoundToRoute();
    /// @notice Scaled input does not fit the PoolManager's int128 delta domain.
    error AmountOverflow();

    constructor(address nullRouter_, address poolManager_, address nativeView_, uint8 scalePow10_)
        BaseAdapter(nullRouter_)
    {
        require(poolManager_ != address(0) && nativeView_ != address(0), "V4_ZERO_ADDR");
        require(scalePow10_ <= 18, "V4_SCALE");
        POOL_MANAGER = IPoolManager(poolManager_);
        NATIVE_VIEW = nativeView_;
        SCALE = 10 ** uint256(scalePow10_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(PoolKey) — the FULL key, hooks included.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        PoolKey memory key = abi.decode(extraData, (PoolKey));
        bool zeroForOne = _asToken(key.currency0) == tokenIn;

        // H1: bind the key to the route. Native currency (address(0)) is the NATIVE_VIEW side.
        address inCurrency = zeroForOne ? key.currency0 : key.currency1;
        address outCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (_asToken(inCurrency) != tokenIn || _asToken(outCurrency) != tokenOut || tokenIn == tokenOut) {
            revert KeyNotBoundToRoute();
        }

        // Pool units: a native-in leg pays raw wei. The router's NATIVE_VIEW push already credited
        // exactly amountIn * SCALE wei to this contract (view semantics), so settle{value} has it.
        uint256 amountSpecified = inCurrency == address(0) ? amountIn * SCALE : amountIn;
        if (amountSpecified > uint256(uint128(type(int128).max))) revert AmountOverflow();

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(CallbackData({key: key, amountSpecified: amountSpecified, zeroForOne: zeroForOne, recipient: to}))
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @dev V4 native currency is address(0); the router's token view of that side is NATIVE_VIEW.
    function _asToken(address currency) internal view returns (address) {
        return currency == address(0) ? NATIVE_VIEW : currency;
    }

    /// @dev Called by PoolManager during unlock. Executes swap + settle + take.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        CallbackData memory cb = abi.decode(data, (CallbackData));

        // 1. Swap (exact input = negative amountSpecified). The returned delta already includes any
        //    hook-returned deltas (fee skims), so it is what we really owe / are owed.
        int256 balanceDelta = POOL_MANAGER.swap(
            cb.key,
            IPoolManager.SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(cb.amountSpecified),
                sqrtPriceLimitX96: cb.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 delta0 = int128(balanceDelta >> 128);
        int128 delta1 = int128(balanceDelta);

        // 2. Settle the input we owe (the negative side of the delta — a hook may charge less than
        //    amountSpecified, never more for exact-input).
        address inCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        int128 inDelta = cb.zeroForOne ? delta0 : delta1;
        uint256 owed = inDelta < 0 ? uint256(uint128(-inDelta)) : 0;
        if (inCurrency == address(0)) {
            POOL_MANAGER.settle{value: owed}();
        } else {
            POOL_MANAGER.sync(inCurrency);
            TransferLib.safeTransfer(inCurrency, address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
        }

        // 3. Take the output we are owed.
        address outCurrency = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;
        int128 outDelta = cb.zeroForOne ? delta1 : delta0;
        uint256 rawOut = outDelta > 0 ? uint256(uint128(outDelta)) : 0;

        uint256 amountOut;
        if (outCurrency == address(0)) {
            // Native out: take raw wei here, forward the NATIVE_VIEW units (the predeploy's transfer
            // moves native). Sub-unit remainder (< SCALE wei) stays — dust by construction.
            POOL_MANAGER.take(address(0), address(this), rawOut);
            amountOut = rawOut / SCALE;
            if (amountOut > 0) TransferLib.safeTransfer(NATIVE_VIEW, cb.recipient, amountOut);
        } else {
            POOL_MANAGER.take(outCurrency, cb.recipient, rawOut);
            amountOut = rawOut;
        }

        return abi.encode(amountOut);
    }

    // Accept native from PoolManager.take() (and the predeploy's view semantics of the router push).
    receive() external payable {}
}
