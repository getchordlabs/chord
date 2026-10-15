// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IAdapterRegistry} from "./interfaces/IAdapterRegistry.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";
import {TransferLib} from "./libraries/TransferLib.sol";

/// @title NullExecutor
/// @notice Execution logic for swap routes. Called by NullRouter via delegatecall.
/// @dev This contract is meant to be called via delegatecall from NullRouter.
///      All storage reads/writes happen in NullRouter's context.
///      This is a library-style contract — no own state, no proxy.
///
///      DEAD CODE, STILL AN ADDRESS (audit 2026-08-05, L9). The delegatecall path was removed on
///      2026-03-20 (44-gas revert on Monad) — NullRouter calls adapters directly and keeps
///      `executor` only for storage layout. But the deployed instance is still callable by anyone,
///      and the whitelist it enforced was a CALLER-SUPPLIED `registry` argument: an attacker
///      deploys a registry whose `isApproved` returns true, names themselves as the "adapter", and
///      `TransferLib.safeTransfer` moves this contract's own balance to them. Balance is 0 today,
///      so the loss was ~$0 — but it is an unprotected sweep on an address the public docs list as
///      a core contract.
///
///      Fix: the registry is pinned at construction. The `registry` parameter is retained on every
///      entrypoint so the ABI (and the historical delegatecall call sites) still match, but it is
///      now only ASSERTED to equal the pinned one — supplying anything else reverts before a single
///      token moves. It is deliberately not silently ignored: a caller passing a foreign registry
///      is doing something wrong and should hear about it.
contract NullExecutor {
    error UnapprovedAdapter(address adapter);
    error InsufficientOutput(uint256 got, uint256 minRequired);
    error ZeroAmountIn();
    error RegistryMismatch(address supplied, address expected);
    error ZeroRegistry();

    /// @notice The only whitelist this executor will honour. Immutable — see the L9 note above.
    IAdapterRegistry public immutable REGISTRY;

    /// @param registry_ AdapterRegistry proxy for this chain.
    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroRegistry();
        REGISTRY = IAdapterRegistry(registry_);
    }

    /// @notice Execute a single route step
    /// @param step The route step to execute
    /// @param registry Must equal the pinned REGISTRY (retained for ABI compatibility)
    /// @return amountOut Amount of output tokens received
    function executeSingle(
        INullRouter.RouteStep calldata step,
        IAdapterRegistry registry
    ) external returns (uint256 amountOut) {
        _validateAdapter(address(registry), step.adapter);

        // Transfer input tokens to adapter
        TransferLib.safeTransfer(step.tokenIn, step.adapter, step.amountIn);

        // Execute swap via adapter
        amountOut = IAdapter(step.adapter).swap(
            step.tokenIn,
            step.tokenOut,
            step.amountIn,
            address(this), // tokens come back to router (delegatecall context)
            step.extraData
        );
    }

    /// @notice Execute a split swap across multiple DEXs
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param steps Array of route steps (amounts must sum to total amountIn)
    /// @param registry Must equal the pinned REGISTRY (retained for ABI compatibility)
    /// @return totalOut Total output amount across all splits
    function executeSplit(
        address tokenIn,
        address tokenOut,
        INullRouter.RouteStep[] calldata steps,
        IAdapterRegistry registry
    ) external returns (uint256 totalOut) {
        for (uint256 i = 0; i < steps.length; i++) {
            _validateAdapter(address(registry), steps[i].adapter);

            // Transfer this step's portion to the adapter
            TransferLib.safeTransfer(tokenIn, steps[i].adapter, steps[i].amountIn);

            // Execute swap
            uint256 stepOut = IAdapter(steps[i].adapter).swap(
                tokenIn,
                tokenOut,
                steps[i].amountIn,
                address(this),
                steps[i].extraData
            );

            totalOut += stepOut;
        }
    }

    /// @notice Execute a multi-hop swap (A → B → C)
    /// @param steps Ordered route steps for each hop
    /// @param registry Must equal the pinned REGISTRY (retained for ABI compatibility)
    /// @return amountOut Final output amount
    function executeMultiHop(
        INullRouter.RouteStep[] calldata steps,
        IAdapterRegistry registry
    ) external returns (uint256 amountOut) {
        require(steps.length >= 2, "MIN_2_HOPS");

        uint256 currentAmount;

        for (uint256 i = 0; i < steps.length; i++) {
            _validateAdapter(address(registry), steps[i].adapter);

            // First hop uses the specified amountIn; subsequent hops use output from previous
            uint256 amountIn = i == 0 ? steps[i].amountIn : currentAmount;

            // Transfer to adapter
            TransferLib.safeTransfer(steps[i].tokenIn, steps[i].adapter, amountIn);

            // Execute swap
            currentAmount = IAdapter(steps[i].adapter).swap(
                steps[i].tokenIn,
                steps[i].tokenOut,
                amountIn,
                address(this),
                steps[i].extraData
            );
        }

        amountOut = currentAmount;
    }

    // ============================================================
    // Internal
    // ============================================================

    /// @dev Whitelist check against the PINNED registry. The supplied address is only compared,
    ///      never called — calling it is exactly the L9 bug.
    function _validateAdapter(address registry, address adapter) internal view {
        if (registry != address(REGISTRY)) revert RegistryMismatch(registry, address(REGISTRY));
        if (!REGISTRY.isApproved(adapter)) {
            revert UnapprovedAdapter(adapter);
        }
    }
}
