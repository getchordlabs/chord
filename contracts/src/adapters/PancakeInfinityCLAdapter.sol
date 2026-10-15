// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @dev PancakeSwap Infinity PoolKey — (currency0, currency1, hooks, poolManager, fee, parameters). `parameters` packs the
///      hooks registration bitmap (bits 0..15) and, for CL pools, tickSpacing (int24 at bits 16..39).
struct InfinityPoolKey {
    address currency0;
    address currency1;
    address hooks;
    address poolManager;
    uint24 fee;
    bytes32 parameters;
}

interface IInfinityVault {
    function lock(bytes calldata data) external returns (bytes memory);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IInfinityCLPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev Returns BalanceDelta (amount0 = upper 128 bits, amount1 = lower 128 bits; positive = owed to the locker).
    function swap(InfinityPoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 delta);
}

interface IWrappedNativeI {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title PancakeInfinityCLAdapter
/// @notice Swaps on PancakeSwap Infinity CL pools (BNB Chain): `Vault.lock` → `lockAcquired` → `CLPoolManager.swap` →
///         settle the input into the Vault → take the output. Infinity is Uniswap-V4-shaped but splits the singleton:
///         accounting (lock / sync / settle / take) lives in the Vault, swaps in the CL pool manager, and the PoolKey
///         names its pool manager. Exact input = negative `amountSpecified` (CLPool: `exactInput = amountSpecified < 0`).
/// @dev Provenance, as in UniswapV4Adapter: there is no pool contract to check against a factory — funds only move to
///      the IMMUTABLE Vault — so the key is BOUND to the route (its currencies must be exactly tokenIn / tokenOut, native
///      currency0 = the wrapped native the router hands adapters) and must name the pinned CL pool manager. Which pools
///      (and which hooks) are routed is the engine's call; a hook can make execution differ from a quote, so the engine
///      only emits vanilla pools and hooks verified by real both-ways swaps.
contract PancakeInfinityCLAdapter is IAdapter, BaseAdapter {
    IInfinityVault public immutable VAULT;
    IInfinityCLPoolManager public immutable CL_POOL_MANAGER;
    address public immutable WRAPPED_NATIVE;

    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    struct CallbackData {
        InfinityPoolKey key;
        uint128 amountIn;
        bool zeroForOne;
        address recipient;
    }

    error NotVault();
    error KeyNotBoundToRoute();
    error WrongPoolManager();
    error ZeroOutput();
    error PartialFill();
    error AmountTooLarge();

    constructor(address nullRouter_, address vault_, address clPoolManager_, address wrappedNative_) BaseAdapter(nullRouter_) {
        require(vault_ != address(0) && clPoolManager_ != address(0) && wrappedNative_ != address(0), "INF_ZERO_ADDR");
        VAULT = IInfinityVault(vault_);
        CL_POOL_MANAGER = IInfinityCLPoolManager(clPoolManager_);
        WRAPPED_NATIVE = wrappedNative_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(InfinityPoolKey).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        InfinityPoolKey memory key = abi.decode(extraData, (InfinityPoolKey));
        if (key.poolManager != address(CL_POOL_MANAGER)) revert WrongPoolManager();
        bool zeroForOne = _asToken(key.currency0) == tokenIn;
        address inCurrency = zeroForOne ? key.currency0 : key.currency1;
        address outCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (_asToken(inCurrency) != tokenIn || _asToken(outCurrency) != tokenOut) revert KeyNotBoundToRoute();

        // Native input: the router handed us the wrapped native — unwrap it to settle native.
        if (inCurrency == address(0)) IWrappedNativeI(WRAPPED_NATIVE).withdraw(amountIn);

        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        bytes memory result = VAULT.lock(
            abi.encode(CallbackData({key: key, amountIn: uint128(amountIn), zeroForOne: zeroForOne, recipient: to}))
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @dev Infinity native currency is address(0); the router's view of that side is the wrapped native.
    function _asToken(address currency) internal view returns (address) {
        return currency == address(0) ? WRAPPED_NATIVE : currency;
    }

    /// @dev Called by the Vault inside `lock`: swap, settle the input, take the output.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault();
        CallbackData memory cb = abi.decode(data, (CallbackData));

        int256 delta = CL_POOL_MANAGER.swap(
            cb.key,
            IInfinityCLPoolManager.SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(uint256(cb.amountIn)),
                sqrtPriceLimitX96: cb.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 delta0 = int128(delta >> 128);
        int128 delta1 = int128(delta);

        address inCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        address outCurrency = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;
        int128 outDelta = cb.zeroForOne ? delta1 : delta0;
        if (outDelta <= 0) revert ZeroOutput();
        uint256 amountOut = uint256(uint128(outDelta));

        // Settle the input. An exact-input swap that runs out of liquidity before the price limit charges LESS than
        // amountIn; the remainder would sit in this contract with no way back to the user, so a partial fill reverts
        // (the V4 adapter gets the same outcome implicitly: it overpays and the unlock fails CurrencyNotSettled).
        int128 inDelta = cb.zeroForOne ? delta0 : delta1;
        if (inDelta != -int128(cb.amountIn)) revert PartialFill();
        if (inCurrency == address(0)) {
            VAULT.settle{value: cb.amountIn}();
        } else {
            VAULT.sync(inCurrency);
            TransferLib.safeTransfer(inCurrency, address(VAULT), cb.amountIn);
            VAULT.settle();
        }

        if (outCurrency == address(0)) {
            VAULT.take(address(0), address(this), amountOut);
            IWrappedNativeI(WRAPPED_NATIVE).deposit{value: amountOut}();
            TransferLib.safeTransfer(WRAPPED_NATIVE, cb.recipient, amountOut);
        } else {
            VAULT.take(outCurrency, cb.recipient, amountOut);
        }
        return abi.encode(amountOut);
    }

    /// @dev Native from the wrapped-native `withdraw` and from `Vault.take`.
    receive() external payable {}
}
