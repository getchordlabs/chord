// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title NadFunV2Adapter
/// @notice Buys nad.fun bonding-curve **V2** tokens (the current mint standard;
///         V1 tokens use NadFunBCAdapter). The V2 router exposes a flat-param
///         payable buy — `buy(uint256 amountOutMin, address token, address to,
///         uint256 deadline)` with selector 0xaf47a8bb (its Solidity name isn't
///         `buy`, so we call it by raw selector) — and a
///         `getAmountOut(address,uint256,bool)→uint256` quoter used off-chain by
///         the engine.
/// @dev BUY-ONLY: V2 sells are permit-signed (EIP-2612 style, user signature),
///      which a permissionless adapter can't produce, so token→WMON reverts.
///      Sniper buys pre-graduation V2 mints; exit via nad.fun or post-graduation
///      Capricorn. Native-MON slippage is enforced upstream by NullRouter's
///      minAmountOut (this passes amountOutMin=1).
///
///      Flow (isBuy=true): NullRouter pulls native MON and wraps → WMON reaches
///      here; unwrap WMON→MON; router.buy{value}(1, token, to, deadline) sends
///      the token straight to `to`; amountOut = balance delta on `to`.
///
///      H1/M9 (2026-08-05 audit): the destination is the IMMUTABLE V2 router, but swap() was
///      world-callable (`onlyRouter` now) and `token` was unbound to the route — the adapter measured
///      a balanceOf delta of `token` that the router consumed as an amount of `route.tokenOut`.
contract NadFunV2Adapter is IAdapter, BaseAdapter {
    address public immutable V2_ROUTER;
    address public immutable WMON;

    /// @dev Flat-param V2 buy: buy(uint256 amountOutMin, address token, address to, uint256 deadline) payable
    bytes4 private constant BUY_SELECTOR = 0xaf47a8bb;

    error V2SellUnsupported();
    error V2BuyFailed();
    /// @notice extraData's `token` is not the route's tokenOut, or tokenIn is not WMON.
    error TokenNotBoundToRoute();

    constructor(address nullRouter_, address v2Router_, address wmon_) BaseAdapter(nullRouter_) {
        require(v2Router_ != address(0) && wmon_ != address(0), "NADV2_ZERO_ADDR");
        V2_ROUTER = v2Router_;
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address token, bool isBuy). Only isBuy=true supported.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address token, bool isBuy) = abi.decode(extraData, (address, bool));
        if (!isBuy) revert V2SellUnsupported();
        // M9: buy-only, so the route MUST be WMON → token. Nothing enforced either half before, and
        // in particular nothing required tokenIn == WMON before unwrapping it.
        if (token != tokenOut || tokenIn != WMON) revert TokenNotBoundToRoute();

        // WMON → native MON, then buy on the V2 curve, token delivered to `to`.
        IWMON(WMON).withdraw(amountIn);
        uint256 balBefore = IERC20(token).balanceOf(to);
        (bool ok, ) = V2_ROUTER.call{value: amountIn}(
            abi.encodeWithSelector(BUY_SELECTOR, uint256(1), token, to, block.timestamp + 300)
        );
        if (!ok) revert V2BuyFailed();
        amountOut = IERC20(token).balanceOf(to) - balBefore;

        // M9: a curve refund (graduation boundary) arrives as native MON and would otherwise be
        // unreachable forever on this immutable, ownerless adapter. Re-wrap and forward it.
        uint256 residual = address(this).balance;
        if (residual > 0) {
            IWMON(WMON).deposit{value: residual}();
            TransferLib.safeTransfer(WMON, to, residual);
        }
    }

    receive() external payable {}
}
