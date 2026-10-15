// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeCollector} from "../FeeCollector.sol";

/// @title ChordFeeCollector
/// @notice Chord's fee collector — `FeeCollector` unchanged under the Chord name (no new state; a FeeCollector
///         proxy upgrades to it in place).
/// @custom:oz-upgrades-unsafe-allow constructor
contract ChordFeeCollector is FeeCollector {}
