// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Erc4626DepositAdapter} from "../adapters/Erc4626DepositAdapter.sol";

/// @title ChordErc4626DepositAdapter — `Erc4626DepositAdapter` (buy an ERC-4626 share token by depositing the
///        vault's asset, native-coin vaults included) under the Chord name. Same constructor, same H1 router pin.
///        First deployment: Monad (aprMON, shMON, gMON).
contract ChordErc4626DepositAdapter is Erc4626DepositAdapter {
    constructor(address router_, address wrappedNative_) Erc4626DepositAdapter(router_, wrappedNative_) {}
}
