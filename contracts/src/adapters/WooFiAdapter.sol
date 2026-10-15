// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice WOOFi's WooPPV2 — one synthetic-proactive-market-maker pool per chain holding a quote token (the chain's
///         USDC / USDT) and several base tokens, priced by WOOFi's own oracle (Wooracle V2.2). Same proxy address on
///         Monad, Avalanche, BNB Chain, Base and Arbitrum: 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4 (read 2026-10-14;
///         selectors read off the Monad implementation 0x6aebc663…: swap 0x7dc20382, query 0xf58a435f).
interface IWooPPV2 {
    function quoteToken() external view returns (address);

    /// @dev The swap's own arithmetic as a view; reverts where `swap` would (oracle not feasible, a size past the
    ///      token's max gamma / max notional, output past the pool's reserve).
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount);

    /// @dev PUSH model: `fromAmount` must already sit in the pool above its book reserve (`balance - reserve`).
    ///      Pays `to` directly and posts the post-trade price back to the oracle.
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        address to,
        address rebateTo
    ) external returns (uint256 realToAmount);
}

/// @title WooFiAdapter
/// @notice Exact-in swaps on WOOFi's WooPPV2 pool: quote token → base, base → quote token, and base → base (the pool
///         sells the first base for its quote token and buys the second with it inside one call).
/// @dev IMMUTABLE, stateless, PUSH model like every Chord adapter: the router transfers tokenIn here BEFORE calling
///      swap(); the adapter hands it to the pool (WooPPV2 takes input by transfer-then-call, the same way WOOFi's own
///      router and every aggregator calling the pool do), the pool pays this adapter, and the output measured by balance
///      delta is forwarded to `to`. The adapter ends every swap holding neither token.
///
///      extraData = abi.encode(address pool) and must equal the pool pinned at construction — WOOFi runs ONE pool per
///      chain, so provenance is a constant, not a registry lookup (H1: a caller cannot point an approval-backed swap at
///      a contract of their choosing). Entry is `onlyRouter`.
///
///      minToAmount = 0 is a venue-level no-op: the Chord router enforces the route's minimum. rebateTo is only an event
///      field in WooPPV2 (no transfer); it names the Chord router so the volume is attributable.
///
///      Oracle venue: the pool moves its own oracle price after every trade (`postPrice`), so two legs of one route
///      through this pool do not add up to their separate quotes. The engine keeps it to ONE leg per route.
///
///      ERC-20 only: the Chord router wraps native before any ERC-20 adapter, so no receive().
contract WooFiAdapter is IAdapter, BaseAdapter {
    /// @notice The chain's WooPPV2 pool.
    IWooPPV2 public immutable POOL;

    /// @notice extraData named a pool other than the pinned WooPPV2.
    error NotWooPool(address pool);
    /// @notice tokenIn == tokenOut.
    error SameToken();
    /// @notice The swap delivered nothing.
    error NoFill();
    error ZeroAddress();

    constructor(address nullRouter_, address pool_) BaseAdapter(nullRouter_) {
        if (pool_ == address(0)) revert ZeroAddress();
        POOL = IWooPPV2(pool_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — the chain's WooPPV2.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata extraData)
        external
        override
        onlyRouter
        returns (uint256 amountOut)
    {
        address pool = abi.decode(extraData, (address));
        if (pool != address(POOL)) revert NotWooPool(pool); // H1 provenance — see contract NatSpec.
        if (tokenIn == tokenOut) revert SameToken();

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        POOL.swap(tokenIn, tokenOut, amountIn, 0, address(this), NULL_ROUTER);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut == 0) revert NoFill();
        TransferLib.safeTransfer(tokenOut, to, amountOut);
    }
}
