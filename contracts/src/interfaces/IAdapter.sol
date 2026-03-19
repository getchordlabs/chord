// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title IAdapter
/// @notice Common interface for all DEX adapters in NullTerminal
/// @dev All adapters are IMMUTABLE (no proxy). Stateless. New adapter = deploy new contract + register.
interface IAdapter {
    /// @notice Execute a swap on the underlying DEX
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @param amountIn Amount of input tokens (in wei)
    /// @param to Address to receive output tokens
    /// @param extraData DEX-specific parameters (pool address, fee tier, etc.)
    /// @return amountOut Amount of output tokens received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external returns (uint256 amountOut);
}
