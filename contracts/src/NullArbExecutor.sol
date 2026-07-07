// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {TransferLib} from "./libraries/TransferLib.sol";

/// @title NullArbExecutor
/// @notice Fee-free sibling of NullRouter._executeMultiHop for the operator's own arb bot. Calls the SAME
///         AdapterRegistry-whitelisted adapters, minus the 5bps fee. Owner-operated; pre-funded per call
///         (no flash loans).
/// @dev Adapters are permissionless (IAdapter.swap is `external`, no onlyRouter) and follow a strict
///      transfer-then-call pattern: the caller sends tokenIn TO the adapter, then calls
///      adapter.swap(tokenIn, tokenOut, amtIn, to, extraData) which credits the output to `to`. This
///      contract replicates NullRouter._executeMultiHop exactly, minus the FeeCollector cut, to run an
///      atomic WMON->X->...->WMON (or any) cycle in a single tx.
///
///      FUND SAFETY: this contract holds token balances only transiently, within a single `arb()` call.
///      amountIn is pulled fresh from msg.sender every call, and hops chain strictly (hop-continuity
///      guard below), so no arbitrary standing balance can be pushed through a whitelisted adapter and
///      swept. The final output is forwarded to msg.sender in full — no fee is retained. Any residual
///      dust that somehow accrues is recoverable ONLY by the owner via `rescue`.
contract NullArbExecutor is ReentrancyGuard, Ownable {
    /// @notice One leg of an arb cycle. Same shape as NullRouter.RouteStep.
    /// @param adapter   Whitelisted DEX adapter to call (same addresses the NullRouter uses).
    /// @param tokenIn   Input token for this hop.
    /// @param tokenOut  Output token for this hop.
    /// @param amountIn  Only meaningful for hop 0 (the entry amount); later hops consume the prior output.
    /// @param extraData DEX-specific params from the engine quote (pool address, fee tier, PoolKey, ...).
    struct RouteStep {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        bytes extraData;
    }

    error Expired();
    error EmptyRoute();
    error ZeroAmount();
    error HopTokenMismatch();
    error InsufficientOutput(uint256 got, uint256 minRequired);

    /// @param owner_ The arb bot operator (holds rescue rights).
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Execute an atomic multi-leg arb cycle through whitelisted adapters, fee-free.
    /// @dev Mirrors NullRouter._executeMultiHop: transfer-then-call per hop, output credited to THIS
    ///      contract, chained forward under a strict hop-continuity guard. No fee is taken; the full
    ///      final output is returned to msg.sender.
    /// @param amountIn     Entry amount of routes[0].tokenIn to pull from msg.sender (must be pre-approved).
    /// @param minAmountOut Minimum acceptable final output — the revert-protection for an unprofitable arb.
    /// @param deadline     Unix timestamp after which the call reverts.
    /// @param routes       Ordered hops of the cycle; routes[i].tokenIn must equal routes[i-1].tokenOut.
    /// @return amountOut   Final output delivered to msg.sender.
    function arb(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (routes.length == 0) revert EmptyRoute();
        if (amountIn == 0) revert ZeroAmount();

        // 1. Pull the entry token fresh from the caller (bot must approve this executor, like the router).
        TransferLib.safeTransferFrom(routes[0].tokenIn, msg.sender, address(this), amountIn);

        // 2. Walk the cycle. Each hop consumes exactly what the prior hop produced.
        for (uint256 i = 0; i < routes.length; i++) {
            // Hop continuity: hop i must consume exactly what hop i-1 produced. Without this, the
            // forwarded amount (`amountOut` of the prior hop) is decoupled from `routes[i].tokenIn`,
            // letting a caller push this contract's standing balance of an ARBITRARY token through a
            // whitelisted adapter and sweep the proceeds — draining any leftover/donated/over-delivered
            // tokens. (routes[0].tokenIn is constrained by the entry pull of amountIn above.)
            if (i > 0 && routes[i].tokenIn != routes[i - 1].tokenOut) revert HopTokenMismatch();

            uint256 amtIn = i == 0 ? amountIn : amountOut;

            // Transfer-then-call: fund the adapter, then have it credit output back to THIS contract.
            TransferLib.safeTransfer(routes[i].tokenIn, routes[i].adapter, amtIn);
            amountOut = IAdapter(routes[i].adapter).swap(
                routes[i].tokenIn, routes[i].tokenOut, amtIn, address(this), routes[i].extraData
            );
        }

        // 3. Revert-protection: an unprofitable cycle bails before we deliver.
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        // 4. Deliver the full final output to the caller — NO fee taken.
        TransferLib.safeTransfer(routes[routes.length - 1].tokenOut, msg.sender, amountOut);
    }

    /// @notice Owner-only recovery of any dust/stuck token balance.
    /// @dev The arb flow leaves no standing balance in the common path; this covers adapter
    ///      over-delivery, accidental transfers, or a partially-filled leg.
    function rescue(address token, uint256 amt, address to) external onlyOwner {
        TransferLib.safeTransfer(token, to, amt);
    }
}
