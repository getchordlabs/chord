// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AdapterRegistry} from "../AdapterRegistry.sol";

/// @title ChordAdapterRegistry
/// @notice Chord's adapter whitelist — `AdapterRegistry` unchanged under the Chord name (no new state; an
///         AdapterRegistry proxy upgrades to it in place).
/// @custom:oz-upgrades-unsafe-allow constructor
contract ChordAdapterRegistry is AdapterRegistry {}
