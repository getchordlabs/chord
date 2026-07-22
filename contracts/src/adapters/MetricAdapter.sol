// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Metric OMM (legacy deployment) shared SwapRouter — one router for all pools, pool
///         address passed per-call. Selector verified on Monad mainnet bytecode 2026-07-22:
///         swapExactInput 0x4a878c1c. Router 0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5.
interface IMetricSwapRouter {
    /// @notice Exact-in swap on a single OMM pool. The router pulls only `amountInUsed` (which can
    ///         be less than `amountIn` on a partial fill) via transferFrom and sends `amountOut`
    ///         of the output token to `recipient`.
    function swapExactInput(
        address pool,
        address recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 priceLimitX64,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 amountInUsed);
}

/// @notice OMM pool immutables — only token0/token1 are consumed here (direction derivation).
///         Selector verified: getImmutables 0xbcdb4dad.
interface IMetricPool {
    function getImmutables()
        external
        view
        returns (
            address factory,
            address priceProvider,
            address token0,
            address token1,
            uint104,
            uint104,
            uint104,
            bool,
            uint256,
            uint256,
            int16,
            int16,
            uint256,
            uint256
        );
}

/// @title MetricAdapter
/// @notice Executes exact-in swaps on Metric OMM pools via the shared SwapRouter.
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn here BEFORE calling swap();
///      this adapter never transferFrom's the caller. Output is measured by balance delta and
///      forwarded to `to`; the adapter ends every swap with ZERO balance of tokenIn and tokenOut.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived ON-CHAIN from the pool's
///      getImmutables() token0/token1 (zeroForOne = tokenIn == token0) — encoding direction
///      off-chain would recreate the stale-extraData bug class.
///
///      minAmountOut=0 and deadline=now+300 are venue-level no-ops — NullRouter enforces the real
///      slippage + deadline globally. priceLimitX64 is a no-bound sentinel: 1 when selling token0
///      (price can only move down), type(uint128).max when selling token1 (price moves up).
///
///      Partial fills: the router pulls only `amountInUsed` from the exact-amount approval; the
///      unused remainder stays on this adapter and is forwarded to `to` after the output (router
///      dust-sweep returns it to the user on single-hop).
///
///      Oracle dependency: the pool reads its own PriceProvider during execution (no oracle args).
///      If the provider's push feed is >4s stale, execution reverts with WrappedError(FeedStalled)
///      — nothing for this adapter to handle; the revert simply bubbles to NullRouter.
///
///      ERC20-only: pools are WMON-based and NullRouter wraps MON->WMON before any ERC20 adapter,
///      so this contract never sees native — no receive() needed.
contract MetricAdapter is IAdapter {
    /// @notice Metric OMM shared SwapRouter (no cross-check view exists on it — pinned as given).
    IMetricSwapRouter public immutable ROUTER;

    /// @notice Venue-level deadline no-op window (NullRouter enforces the real deadline).
    uint256 private constant EXPIRY_WINDOW = 300;

    constructor(address router_) {
        ROUTER = IMetricSwapRouter(router_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — the Metric OMM pool.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));

        (,, address token0, address token1,,,,,,,,,,) = IMetricPool(pool).getImmutables();

        bool zeroForOne;
        if (tokenIn == token0 && tokenOut == token1) {
            zeroForOne = true;
        } else if (tokenIn == token1 && tokenOut == token0) {
            zeroForOne = false;
        } else {
            revert("METRIC_PAIR_MISMATCH");
        }

        require(amountIn <= type(uint128).max, "METRIC_OVERFLOW");

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);
        ROUTER.swapExactInput(
            pool,
            address(this),
            zeroForOne,
            uint128(amountIn),
            zeroForOne ? 1 : type(uint128).max, // no-bound price limit sentinel per direction
            0, // minAmountOut — NullRouter's global minOut is the real protection
            block.timestamp + EXPIRY_WINDOW
        );
        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut > 0, "METRIC_NO_FILL");
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Partial-fill remainder (router pulled only amountInUsed) -> back to `to`; the router's
        // dust-sweep returns it to the user on single-hop. Adapter MUST end at zero balance.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }
}
