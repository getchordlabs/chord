// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AlignedStackDeploy} from "./lib/AlignedStackDeploy.sol";
import {ChordV3Adapter, ChordV2FeeAdapter, ChordV4Adapter} from "../src/chord/ChordAdapters.sol";
import {UniV3AnyForkAdapter} from "../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2FeeTaxSafeAdapter} from "../src/adapters/UniV2FeeTaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice NullTerminal core stack + adapter set on **BNB Chain (56)** — docs/bnb-contracts-deploy.md.
/// @dev PREPARED, NOT BROADCAST (2026-09-30). Venue facts: docs/bnb-tape.md (recon 2026-09-30); every factory
///      below was re-probed on-chain for its registry SHAPE before being pinned. Base fee 0, validators take
///      ≥ 0.05 gwei (eth_maxPriorityFeePerGas = 0.05 gwei, read 2026-09-30):
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployBnb.s.sol \
///          --rpc-url "$BNB_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      Proxies land on 0x6Cf25d2a… / 0x1B1Fee89… / 0x6C662296… only from 0x0f11…4f79 at nonce 0.
contract DeployBnbScript is AlignedStackDeploy {
    // ── tokens (ALL 18 decimals on BNB, incl. the stables — read on-chain) ───────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant FDUSD = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // ── V3 family (UniV3AnyForkAdapter) — registry SHAPE probed per factory 2026-09-30 ────────────
    // AnyFork (a superset of UniV3GenericAdapter: PancakeSwap / Uniswap pools authenticate in the same
    // fee lane before the extra lane is ever reached) because Topaz answers ONLY getPool(a,a,int24):
    // pool 0x767f1f4b… (WBNB/USDT, ts 50, dynamic fee() 43) — every uint24 probe reverts.
    //                                                          shape                    24h USD (recon)
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865; // getPool(uint24), static fee   $931M
    address internal constant UNISWAP_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7; // getPool(uint24), static fee   $53M
    address internal constant TOPAZ_FACTORY = 0x73DC984D9490286E735548f61dfCCec67Af82ed9; // getPool(int24)                 $11.7M
    address internal constant THENA_V3_FACTORY = 0x30055F87716d3DFD0E5198C27024481099fB4A98; // poolByPair (Algebra Integral) $1.4M
    // NOT pinned: THENA Fusion (Algebra v1, $0.2M), SquadSwap V3 / tiktokfun / Sushi V3 / Unchain X (<$0.7M each),
    // two unnamed V3 forks (not on GeckoTerminal). THENA V3 CustomPools are not in poolByPair — refused.

    // ── V2 (UniV2FeeTaxSafeAdapter) ──────────────────────────────────────────────────────────────
    // NOT UniV2TaxSafeAdapter: it hardcodes 0.3 %, and PancakeSwap V2 — the only V2 venue that matters here
    // (~$1.4B/24h ex-wash) — charges 0.25 % (PancakeRouter.getAmountOut: 9975/10000). The fee-parameterised
    // variant also reads reserves AFTER the push, which BNB's swap-and-liquify tax tokens need (23 % of
    // V2 swaps carry a transfer tax — docs/bnb-tape.md §5.6).
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73; // getPair(a,a)
    uint16 internal constant PANCAKE_V2_FEE_BPS = 25;
    // NOT pinned: Biswap / Nomiswap (per-PAIR fees — not expressible per factory), PancakeSwap V1, ApeSwap,
    // BabySwap, FstSwap, MDEX, Uniswap V2, SquadSwap V2, Sushi V2 (each < $0.8M/24h, fees unverified),
    // Nomiswap Stable (stableswap behind the V2 topic), Flap pools (bonding-curve pairs, factory() reverts).

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────
    address internal constant V4_POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    // NOT served: PancakeSwap Infinity CL ($267M/24h, 14 % of pool swaps, 81 % through hooks) and Infinity Bin —
    // Vault + CLPoolManager ABI with a different PoolKey (poolManager + bytes32 parameters). Needs its own adapter.

    function chainIdExpected() public pure override returns (uint256) {
        return 56;
    }

    function chainName() public pure override returns (string memory) {
        return "BNB Chain (56)";
    }

    function wrappedNative() public pure override returns (address) {
        return WBNB;
    }

    function v3Factories() public pure returns (address[] memory f) {
        f = new address[](4);
        f[0] = PANCAKE_V3_FACTORY;
        f[1] = UNISWAP_V3_FACTORY;
        f[2] = TOPAZ_FACTORY;
        f[3] = THENA_V3_FACTORY;
    }

    /// @dev ALL ZERO = registry lane. (PancakeSwap V3 pools are CREATE2'd by its PoolDeployer, not the factory,
    ///      so a factory-keyed hash could not work for it anyway.)
    function v3InitCodeHashes() public pure returns (bytes32[] memory h) {
        h = new bytes32[](4);
    }

    /// @dev EMPTY: both fee-keyed factories are static-fee (PancakeSwap tiers 100/500/2500/10000 and Uniswap
    ///      100/500/3000/10000 — fee() IS the key); Topaz is tickSpacing-keyed (pass 3), THENA pair-keyed (pass 1).
    function v3FeeTiers() public pure returns (uint24[] memory t) {
        t = new uint24[](0);
    }

    function v2Factories() public pure returns (address[] memory f, uint16[] memory fees) {
        f = new address[](1);
        fees = new uint16[](1);
        f[0] = PANCAKE_V2_FACTORY;
        fees[0] = PANCAKE_V2_FEE_BPS;
    }

    function _deployV3Adapter(address router) internal override returns (address) {
        return address(new ChordV3Adapter(router, v3Factories(), v3InitCodeHashes(), v3FeeTiers()));
    }

    function _deployOtherAdapters(address router)
        internal
        override
        returns (address[] memory adapters, string[] memory names)
    {
        (address[] memory f, uint16[] memory fees) = v2Factories();
        adapters = new address[](2);
        names = new string[](2);
        adapters[0] = address(new ChordV2FeeAdapter(router, f, fees)); // nonce 9
        names[0] = "ChordV2FeeAdapter";
        adapters[1] = address(new ChordV4Adapter(router, V4_POOL_MANAGER, WBNB)); // nonce 10
        names[1] = "ChordV4Adapter";
    }

    /// @dev OWNER GATE — docs/fee-tiers.md "stable" + "major" rows (0 bps on the OUTPUT token). NOT included: the
    ///      "USDC"-named `0xe442ca5f…` ("Classic USDC", $0.75) and the " BNB " spoof — anchor strictly by address.
    function zeroFeeTokens() public pure override returns (address[] memory t) {
        t = new address[](7);
        t[0] = USDT;
        t[1] = USDC;
        t[2] = USD1;
        t[3] = FDUSD;
        t[4] = WBNB; // also covers native-BNB output (the router charges on wmon)
        t[5] = BTCB;
        t[6] = ETH;
    }

    function _preflightChain() internal view override {
        address[] memory f = v3Factories();
        for (uint256 i = 0; i < f.length; i++) {
            require(f[i].code.length > 0, "V3 factory has no code");
        }
        require(PANCAKE_V2_FACTORY.code.length > 0, "V2 factory has no code");
        require(V4_POOL_MANAGER.code.length > 0, "V4 PoolManager has no code");
    }
}
