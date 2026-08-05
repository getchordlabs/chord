// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Mento protocol Router (Velodrome/Aerodrome fork adapted for FPMM pools). Interface
///         verified against mento-core `contracts/swap/router/IRouter.sol` 2026-07-25: Route has
///         exactly THREE fields (from, to, factory) — the base Velodrome `stable` bool was removed.
///         Router 0x4861840C2EfB2b98312B0aE34d86fD73E8f9B6f6 on Monad; defaultFactory verified
///         on-chain == FPMMFactory 0xa849b475FE5a4B5C9C3280152c7a1945b907613b.
interface IMentoRouter {
    struct Route {
        address from;
        address to;
        address factory;
    }

    /// @notice Exact-in swap along `routes`. Pulls amountIn from msg.sender via transferFrom
    ///         directly into the first pool, sends final output to `to`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title MentoAdapter
/// @notice Executes exact-in swaps on Mento FPMM (Fixed-Price Market Maker) pools via the Mento
///         Router. FPMM pools price from SortedOracles/ChainlinkRelayer, not reserves.
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn here BEFORE calling swap();
///      this adapter never transferFrom's the caller. Output is measured by balance delta and
///      forwarded to `to`; the adapter ends every swap with ZERO balance of tokenIn and tokenOut.
///
///      extraData = abi.encode(address factory) ONLY — the pool factory for the pair (FPMMFactory
///      today; a new factory is one extraData change away). The Route is constructed ON-CHAIN from
///      the swap() params, so tokenIn/tokenOut can never drift from the encoded route.
///
///      minOut=0 and deadline=now+300 are venue-level no-ops — NullRouter enforces the real
///      slippage + deadline globally.
///
///      Reverts that bubble untouched (correct behaviour, nothing to handle here):
///      - BreakerBox / MarketHoursBreaker halts (FX pairs outside market hours)
///      - TradingLimits (L0/L1/LG) exceeded on either token
///      The engine treats a reverted getAmountsOut as no-quote, so a halted market never routes.
///
///      ERC20-only: every Mento asset is an ERC20 FX/stable token and NullRouter wraps MON->WMON
///      before any ERC20 adapter — this contract never sees native, no receive() needed.
///
///      H1 (2026-08-05 audit): the `factory` in extraData is what the Router uses to LOOK UP the pool
///      it pulls tokens into — a caller-supplied factory therefore chose the destination of the whole
///      input. It is now pinned at construction and extraData must match it exactly, alongside the
///      `onlyRouter` entrypoint gate. A second Mento factory = a new adapter deployment (adapters are
///      immutable anyway); the extraData ABI is unchanged so the engine seam does not move.
contract MentoAdapter is IAdapter, BaseAdapter {
    /// @notice Mento protocol Router (Velodrome-style, pinned at deploy).
    IMentoRouter public immutable ROUTER;

    /// @notice The ONLY pool factory this adapter will route through (FPMMFactory today).
    address public immutable FACTORY;

    /// @notice Venue-level deadline no-op window (NullRouter enforces the real deadline).
    uint256 private constant EXPIRY_WINDOW = 300;

    /// @notice extraData named a factory other than the one pinned at construction.
    error FactoryNotPinned(address factory);

    constructor(address nullRouter_, address router_, address factory_) BaseAdapter(nullRouter_) {
        require(router_ != address(0) && factory_ != address(0), "MENTO_ZERO_ADDR");
        ROUTER = IMentoRouter(router_);
        FACTORY = factory_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address factory) — pool factory for this pair.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address factory = abi.decode(extraData, (address));
        if (factory != FACTORY) revert FactoryNotPinned(factory); // H1 provenance.

        IMentoRouter.Route[] memory routes = new IMentoRouter.Route[](1);
        routes[0] = IMentoRouter.Route({from: tokenIn, to: tokenOut, factory: factory});

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // Router pulls amountIn from this adapter straight into the pool via transferFrom.
        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);
        ROUTER.swapExactTokensForTokens(
            amountIn,
            0, // amountOutMin — NullRouter's global minOut is the real protection
            routes,
            address(this),
            block.timestamp + EXPIRY_WINDOW
        );
        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut > 0, "MENTO_NO_FILL");
        TransferLib.safeTransfer(tokenOut, to, amountOut);
    }
}
