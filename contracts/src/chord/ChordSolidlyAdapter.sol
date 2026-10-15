// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SolidlyPairAdapter} from "../adapters/SolidlyPairAdapter.sol";

/// @title ChordSolidlyAdapter — `SolidlyPairAdapter` (Solidly volatile + stable pairs priced by the pair itself)
///        under the Chord name. Same constructor, same H1 router pin. First deployment: Avalanche, Blackhole V1.
contract ChordSolidlyAdapter is SolidlyPairAdapter {
    constructor(address router_, address[] memory factories_) SolidlyPairAdapter(router_, factories_) {}
}
