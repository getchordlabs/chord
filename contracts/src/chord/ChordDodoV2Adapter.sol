// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DodoV2Adapter} from "../adapters/DodoV2Adapter.sol";

/// @title ChordDodoV2Adapter — `DodoV2Adapter` (DODO V2 pools, provenance by the chain's DODO factories pinned at
///        construction) under the Chord name. Same constructor, same H1 router pin. First deployments: Avalanche +
///        Arbitrum (DPPFactory only — the market-maker pools KyberSwap routes as `dodo-dpp`).
contract ChordDodoV2Adapter is DodoV2Adapter {
    constructor(address router_, address[] memory factories_) DodoV2Adapter(router_, factories_) {}
}
