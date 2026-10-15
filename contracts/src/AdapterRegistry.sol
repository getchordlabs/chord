// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAdapterRegistry} from "./interfaces/IAdapterRegistry.sol";

/// @title AdapterRegistry
/// @notice Whitelist of approved DEX adapters. Only approved adapters can be used by NullExecutor.
/// @dev UUPS upgradeable. Owner-only management.
contract AdapterRegistry is IAdapterRegistry, UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _adapters;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        // UUPS init removed in OZ v5
    }

    // ============================================================
    // Views
    // ============================================================

    function isApproved(address adapter) external view returns (bool) {
        return _adapters.contains(adapter);
    }

    function getApprovedAdapters() external view returns (address[] memory) {
        return _adapters.values();
    }

    function adapterCount() external view returns (uint256) {
        return _adapters.length();
    }

    // ============================================================
    // Admin
    // ============================================================

    function addAdapter(address adapter) external onlyOwner {
        require(adapter != address(0), "ZERO_ADDRESS");
        require(_adapters.add(adapter), "ALREADY_APPROVED");
        emit AdapterAdded(adapter);
    }

    function removeAdapter(address adapter) external onlyOwner {
        require(_adapters.remove(adapter), "NOT_APPROVED");
        emit AdapterRemoved(adapter);
    }

    // ============================================================
    // UUPS
    // ============================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
