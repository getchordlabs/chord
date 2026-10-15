// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAdapterRegistry
/// @notice Whitelist of approved DEX adapters
interface IAdapterRegistry {
    /// @notice Check if an adapter is approved
    function isApproved(address adapter) external view returns (bool);

    /// @notice Add an adapter to the whitelist
    function addAdapter(address adapter) external;

    /// @notice Remove an adapter from the whitelist
    function removeAdapter(address adapter) external;

    /// @notice Get all approved adapters
    function getApprovedAdapters() external view returns (address[] memory);

    event AdapterAdded(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
}
