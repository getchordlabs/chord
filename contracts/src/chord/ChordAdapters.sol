// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UniV3AnyForkAdapter} from "../adapters/UniV3AnyForkAdapter.sol";
import {UniV2TaxSafeAdapter} from "../adapters/UniV2TaxSafeAdapter.sol";
import {UniV2FeeTaxSafeAdapter} from "../adapters/UniV2FeeTaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../adapters/UniswapV4Adapter.sol";

// The adapters the aligned-stack chains deploy (Base / BNB), under Chord names. Each is the audited adapter
// unchanged — same constructor, same immutables, same H1 router pin — so explorers show the Chord name.

/// @title ChordV3Adapter — `UniV3AnyForkAdapter` (direct pool.swap + callback, any V3 fork by factory list).
contract ChordV3Adapter is UniV3AnyForkAdapter {
    constructor(address router_, address[] memory factories_, bytes32[] memory initCodeHashes_, uint24[] memory feeTiers_)
        UniV3AnyForkAdapter(router_, factories_, initCodeHashes_, feeTiers_)
    {}
}

/// @title ChordV2Adapter — `UniV2TaxSafeAdapter` (0.3 % V2 pairs, prices by what the pair really received).
contract ChordV2Adapter is UniV2TaxSafeAdapter {
    constructor(address router_, address[] memory factories_) UniV2TaxSafeAdapter(router_, factories_) {}
}

/// @title ChordV2FeeAdapter — `UniV2FeeTaxSafeAdapter` (V2 pairs with a per-factory fee, swap-and-liquify safe).
contract ChordV2FeeAdapter is UniV2FeeTaxSafeAdapter {
    constructor(address router_, address[] memory factories_, uint16[] memory feeBps_)
        UniV2FeeTaxSafeAdapter(router_, factories_, feeBps_)
    {}
}

/// @title ChordV4Adapter — `UniswapV4Adapter` (PoolManager unlock/settle/take, PoolKey extraData).
contract ChordV4Adapter is UniswapV4Adapter {
    constructor(address router_, address poolManager_, address wrappedNative_)
        UniswapV4Adapter(router_, poolManager_, wrappedNative_)
    {}
}
