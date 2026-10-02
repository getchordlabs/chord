// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PancakeInfinityCLAdapter} from "../adapters/PancakeInfinityCLAdapter.sol";

/// @title ChordInfinityCLAdapter — `PancakeInfinityCLAdapter` (PancakeSwap Infinity CL: Vault lock → CLPoolManager
///        swap → settle / take) under the Chord name. Same constructor, same H1 router pin. First deployment: BNB Chain.
contract ChordInfinityCLAdapter is PancakeInfinityCLAdapter {
    constructor(address router_, address vault_, address clPoolManager_, address wrappedNative_)
        PancakeInfinityCLAdapter(router_, vault_, clPoolManager_, wrappedNative_)
    {}
}
