// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NullRouter} from "../NullRouter.sol";

/// @title ChordRouter
/// @notice Chord's swap router. The logic is `NullRouter`'s, unchanged — this contract exists so the deployed
///         implementation carries the Chord name on explorers. It adds no state, so its storage layout is
///         NullRouter's and an existing NullRouter proxy upgrades to it in place (script/UpgradeChordNames.s.sol).
/// @custom:oz-upgrades-unsafe-allow constructor
contract ChordRouter is NullRouter {}
