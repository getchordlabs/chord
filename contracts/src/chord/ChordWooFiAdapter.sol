// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {WooFiAdapter} from "../adapters/WooFiAdapter.sol";

/// @title ChordWooFiAdapter — `WooFiAdapter` (WOOFi's WooPPV2 pool, pinned at construction) under the Chord name.
///        Same constructor, same H1 router pin. WooPPV2 sits at one address on Monad, Avalanche, BNB Chain, Base and
///        Arbitrum, so every deployment takes the same two arguments. First deployments: Monad + Avalanche.
contract ChordWooFiAdapter is WooFiAdapter {
    constructor(address router_, address pool_) WooFiAdapter(router_, pool_) {}
}
