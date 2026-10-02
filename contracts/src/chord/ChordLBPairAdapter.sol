// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {LBPairAdapter} from "../adapters/LBPairAdapter.sol";

/// @title ChordLBPairAdapter — `LBPairAdapter` (Liquidity Book v2.2 pairs swapped directly) under the Chord name.
///        Same constructor, same H1 router pin. First deployment: Avalanche, Pharaoh DLMM.
contract ChordLBPairAdapter is LBPairAdapter {
    constructor(address router_, address[] memory factories_) LBPairAdapter(router_, factories_) {}
}
