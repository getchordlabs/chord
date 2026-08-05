// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

// Minimal V4 interfaces
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

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title UniswapV4Adapter
/// @notice Executes swaps on Uniswap V4 via direct PoolManager calls (Approach A)
/// @dev Implements IUnlockCallback. Calls poolManager.unlock() → callback handles swap + settle + take.
///
/// Monad V4 contracts:
///   PoolManager: 0x188d586ddcf52439676ca21a244753fa19f9ea8e
///
/// V4 pool: MON(native)/USDC, fee=3000, tickSpacing=60
///
/// H1 (2026-08-05 audit): extraData is a full PoolKey and swap() was world-callable. Funds only ever
/// move to the IMMUTABLE PoolManager (V4 pools are not contracts — a "pool" is a key hash), so there
/// is no address to validate against a factory; provenance here means BINDING the key to the route:
/// the key's two currencies must be exactly the route's (tokenIn, tokenOut), with native currency0
/// mapped to WMON. Without that, a caller could settle the router's input into an unrelated pool.
contract UniswapV4Adapter is IAdapter, BaseAdapter {
    IPoolManager public immutable POOL_MANAGER;
    address public immutable WMON;

    // sqrt(1.0001^MIN_TICK) * 2^96 — minimum price limit for zeroForOne
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    // sqrt(1.0001^MAX_TICK) * 2^96 — maximum price limit for oneForZero
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    struct CallbackData {
        PoolKey key;
        uint128 amountIn;
        bool zeroForOne;
        address recipient;
    }

    error NotPoolManager();
    error SwapFailed();
    /// @notice The PoolKey's currencies are not the route's (tokenIn, tokenOut).
    error KeyNotBoundToRoute();

    constructor(address nullRouter_, address poolManager_, address wmon_) BaseAdapter(nullRouter_) {
        require(poolManager_ != address(0) && wmon_ != address(0), "V4_ZERO_ADDR");
        POOL_MANAGER = IPoolManager(poolManager_);
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(PoolKey)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        PoolKey memory key = abi.decode(extraData, (PoolKey));
        bool zeroForOne = key.currency0 == tokenIn ||
                          (key.currency0 == address(0) && tokenIn == WMON);

        // H1: bind the key to the route. Native currency (address(0)) is the WMON side because
        // NullRouter always hands ERC20 WMON to adapters and this contract wraps/unwraps around it.
        address inCurrency = zeroForOne ? key.currency0 : key.currency1;
        address outCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (
            _asToken(inCurrency) != tokenIn || _asToken(outCurrency) != tokenOut
        ) {
            revert KeyNotBoundToRoute();
        }

        // If input is WMON and pool uses native MON, unwrap
        if (tokenIn == WMON && key.currency0 == address(0)) {
            IWMON(WMON).withdraw(amountIn);
        }

        // Call unlock — triggers unlockCallback below
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(CallbackData({
                key: key,
                amountIn: uint128(amountIn),
                zeroForOne: zeroForOne,
                recipient: to
            }))
        );

        amountOut = abi.decode(result, (uint256));
    }

    /// @dev V4 native currency is address(0); the router's token view of that side is always WMON.
    function _asToken(address currency) internal view returns (address) {
        return currency == address(0) ? WMON : currency;
    }

    /// @dev Called by PoolManager during unlock. Executes swap + settle + take.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        CallbackData memory cb = abi.decode(data, (CallbackData));

        // 1. Execute swap (creates deltas)
        // BalanceDelta: upper 128 bits = amount0, lower 128 bits = amount1
        int256 balanceDelta = POOL_MANAGER.swap(
            cb.key,
            IPoolManager.SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(uint256(cb.amountIn)), // negative = exact input
                sqrtPriceLimitX96: cb.zeroForOne
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Decode BalanceDelta
        int128 delta0 = int128(balanceDelta >> 128);
        int128 delta1 = int128(balanceDelta);

        // 2. Settle input (pay what we owe to PoolManager)
        if (cb.zeroForOne) {
            if (cb.key.currency0 == address(0)) {
                POOL_MANAGER.settle{value: cb.amountIn}();
            } else {
                POOL_MANAGER.sync(cb.key.currency0);
                TransferLib.safeTransfer(cb.key.currency0, address(POOL_MANAGER), cb.amountIn);
                POOL_MANAGER.settle();
            }
        } else {
            if (cb.key.currency1 == address(0)) {
                POOL_MANAGER.settle{value: cb.amountIn}();
            } else {
                POOL_MANAGER.sync(cb.key.currency1);
                TransferLib.safeTransfer(cb.key.currency1, address(POOL_MANAGER), cb.amountIn);
                POOL_MANAGER.settle();
            }
        }

        // 3. Take output (receive what PoolManager owes us)
        uint256 amountOut;
        address outputCurrency;
        if (cb.zeroForOne) {
            amountOut = uint256(uint128(delta1));
            outputCurrency = cb.key.currency1;
        } else {
            amountOut = uint256(uint128(delta0));
            outputCurrency = cb.key.currency0;
        }

        if (outputCurrency == address(0)) {
            // Output is native MON → take to adapter, wrap to WMON, send to recipient
            POOL_MANAGER.take(outputCurrency, address(this), amountOut);
            IWMON(WMON).deposit{value: amountOut}();
            TransferLib.safeTransfer(WMON, cb.recipient, amountOut);
        } else {
            // Output is ERC20 → take directly to recipient
            POOL_MANAGER.take(outputCurrency, cb.recipient, amountOut);
        }

        return abi.encode(amountOut);
    }

    // Accept native MON from WMON.withdraw() and PoolManager.take()
    receive() external payable {}
}
