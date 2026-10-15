// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AlgebraIntegralAdapter} from "../adapters/AlgebraIntegralAdapter.sol";

/// @title ChordAlgebraIntegralAdapter — `AlgebraIntegralAdapter` (Algebra Integral pools, default + custom-deployer)
///        under the Chord name. Same constructor, same H1 router pin. Deployments: Avalanche (Blackhole CL), Base
///        (Hydrex Integral + QuickSwap V4), BNB (THENA V3).
contract ChordAlgebraIntegralAdapter is AlgebraIntegralAdapter {
    constructor(address router_, address[] memory factories_, address[] memory deployers_)
        AlgebraIntegralAdapter(router_, factories_, deployers_)
    {}
}
