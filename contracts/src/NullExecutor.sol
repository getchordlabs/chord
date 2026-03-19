// SPDX-License-Identifier: UNLICENSED
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
contract NullExecutor {
    error UnapprovedAdapter(address adapter);
    error InsufficientOutput(uint256 got, uint256 minRequired);
    error ZeroAmountIn();

    /// @notice Execute a single route step
    /// @param step The route step to execute
    /// @param registry AdapterRegistry to check whitelist
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
    /// @param registry AdapterRegistry to check whitelist
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
    /// @param registry AdapterRegistry to check whitelist
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

    function _validateAdapter(address registry, address adapter) internal view {
        if (!IAdapterRegistry(registry).isApproved(adapter)) {
            revert UnapprovedAdapter(adapter);
        }
    }
}
