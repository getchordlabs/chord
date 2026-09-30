// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AlignedStackDeploy} from "./lib/AlignedStackDeploy.sol";
import {UniV3AnyForkAdapter} from "../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2TaxSafeAdapter} from "../src/adapters/UniV2TaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {LFJAdapter} from "../src/adapters/LFJAdapter.sol";

/// @notice NullTerminal core stack + adapter set on **Avalanche C-Chain (43114)** —
///         docs/avalanche-contracts-deploy.md.
/// @dev PREPARED, NOT BROADCAST (2026-09-30). Venue facts: docs/avalanche-tape.md (recon 2026-09-30); every
///      factory below was re-probed on-chain for its registry SHAPE before being pinned. EIP-1559 — NO `--legacy`.
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployAvalanche.s.sol \
///          --rpc-url "$AVAX_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      Proxies land on 0x6Cf25d2a… / 0x1B1Fee89… / 0x6C662296… only from 0x0f11…4f79 at nonce 0.
contract DeployAvalancheScript is AlignedStackDeploy {
    // ── tokens ───────────────────────────────────────────────────────────────────────────────────
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant USDC_E = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address internal constant USDT_E = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;
    address internal constant WETH_E = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;
    address internal constant BTC_B = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;

    // ── V3 family (UniV3AnyForkAdapter) — registry SHAPE probed per factory 2026-09-30 ────────────
    // AnyFork, not UniV3GenericAdapter: Pharaoh V3 (Ramses CL fork, Avalanche's #1 venue, $66M/24h)
    // answers ONLY getPool(address,address,int24 tickSpacing) — every getPool(…,uint24) probe reverts
    // (measured on the WAVAX/USDC pool 0xf01449c0…, fee() = 800 dynamic, ts 10).
    //                                                          shape                  24h USD (GeckoTerminal)
    address internal constant UNISWAP_V3_FACTORY = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD; // getPool(uint24), static fee  $22.1M
    address internal constant PHARAOH_V3_FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d; // getPool(int24)               $66.4M
    address internal constant PANGOLIN_V3_FACTORY = 0x1128F23D0bc0A8396E9FBC3c0c68f5EA228B8256; // getPool(uint24), DYNAMIC fee $0.97M
    // NOT pinned: Blackhole V3 0x512eb749… (Algebra Integral, $6.35M) — its top pools are CUSTOM-deployer
    // pools: factory.poolByPair(WAVAX, USDC) = 0x0 for both WAVAX/USDC pools (0x41100c6d…, 0x7789fa30…),
    // they live in customPoolByPair(deployer, t0, t1), a lane no adapter here probes.

    // ── V2 (UniV2TaxSafeAdapter) — both are canonical 0.3 % x·y=k factories with getPair(a,a) ────
    address internal constant LFJ_V1_FACTORY = 0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10; // Joe AMM, $0.55M
    address internal constant PANGOLIN_V2_FACTORY = 0xefa94DE7a4656D787667C749f7E1223D71E9FD88; // $0.15M
    // TaxSafe (superset of the generic adapter for standard tokens): Avalanche fee-on-transfer tokens were
    // NOT measured (docs/avalanche-tape.md §5.8 — Arena launchpad pairs are the likely place), so the
    // adapter that survives them costs one balanceOf and nothing else.
    // NOT pinned: Blackhole V2 / Pharaoh legacy (Solidly pairs), Uniswap V2 0x9e5a52f5… (~$0/24h), Arena DEX.

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────
    address internal constant V4_POOL_MANAGER = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;

    // ── Liquidity Book v2.2 (LFJAdapter — the Monad contract, chain-agnostic constructor) ────────
    // Same factory + router addresses as Monad (LFJ deploys them deterministically); router
    // getFactory() == this factory and getWNATIVE() == WAVAX (read 2026-09-30).
    address internal constant LFJ_LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address internal constant LFJ_LB_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c; // v2.2, $4.95M
    // NOT served: LB v2.1 (factory 0x8e42f2F4…, router 0xb4315e87…, $3.43M) — LFJAdapter hardcodes
    // Version.V2_2 in the router path; a v2.1 lane is a version-parameterised variant (not built here).
    // Pharaoh DLMM (LB fork, $0.35M), LB v2.0 (different ABI), Aquaspace, WOOFi, DODO: no adapter.

    function chainIdExpected() public pure override returns (uint256) {
        return 43114;
    }

    function chainName() public pure override returns (string memory) {
        return "Avalanche C-Chain (43114)";
    }

    function wrappedNative() public pure override returns (address) {
        return WAVAX;
    }

    function v3Factories() public pure returns (address[] memory f) {
        f = new address[](3);
        f[0] = UNISWAP_V3_FACTORY;
        f[1] = PHARAOH_V3_FACTORY;
        f[2] = PANGOLIN_V3_FACTORY;
    }

    /// @dev ALL ZERO = registry lane (getPool uint24 / poolByPair / getPool int24). No hash is pinned.
    function v3InitCodeHashes() public pure returns (bytes32[] memory h) {
        h = new bytes32[](3);
    }

    /// @dev Pangolin V3's enabled CREATION tiers (feeAmountTickSpacing ≠ 0 for exactly 100 / 500 / 2500 /
    ///      8000, read 2026-09-30). Pangolin V3 fees are DYNAMIC — measured: USDt/USDC 0x1150403b… fee() 30,
    ///      registered under 100; PNG/WAVAX 0xfc2bb159… fee() 2000, under 500; WETH.e/WAVAX 0x840c5f01…
    ///      fee() 350, under 2500 — so the live fee never authenticates and these candidates must.
    ///      Uniswap V3 is static-fee (live fee() is its key); Pharaoh is tickSpacing-keyed (pass 3).
    function v3FeeTiers() public pure returns (uint24[] memory t) {
        t = new uint24[](4);
        t[0] = 100;
        t[1] = 500;
        t[2] = 2500;
        t[3] = 8000;
    }

    function v2Factories() public pure returns (address[] memory f) {
        f = new address[](2);
        f[0] = LFJ_V1_FACTORY;
        f[1] = PANGOLIN_V2_FACTORY;
    }

    function _deployV3Adapter(address router) internal override returns (address) {
        return address(new UniV3AnyForkAdapter(router, v3Factories(), v3InitCodeHashes(), v3FeeTiers()));
    }

    function _deployOtherAdapters(address router)
        internal
        override
        returns (address[] memory adapters, string[] memory names)
    {
        adapters = new address[](3);
        names = new string[](3);
        adapters[0] = address(new UniV2TaxSafeAdapter(router, v2Factories())); // nonce 9
        names[0] = "UniV2TaxSafeAdapter";
        adapters[1] = address(new UniswapV4Adapter(router, V4_POOL_MANAGER, WAVAX)); // nonce 10
        names[1] = "UniswapV4Adapter";
        adapters[2] = address(new LFJAdapter(router, LFJ_LB_ROUTER, LFJ_LB_FACTORY)); // nonce 11
        names[2] = "LFJAdapter (LB v2.2)";
    }

    /// @dev OWNER GATE — docs/fee-tiers.md "stable" + "major" rows (0 bps on the OUTPUT token).
    function zeroFeeTokens() public pure override returns (address[] memory t) {
        t = new address[](7);
        t[0] = USDC;
        t[1] = USDT;
        t[2] = USDC_E;
        t[3] = USDT_E;
        t[4] = WAVAX; // also covers native-AVAX output (the router charges on wmon)
        t[5] = WETH_E;
        t[6] = BTC_B;
    }

    function _preflightChain() internal view override {
        address[] memory f = v3Factories();
        for (uint256 i = 0; i < f.length; i++) {
            require(f[i].code.length > 0, "V3 factory has no code");
        }
        address[] memory g = v2Factories();
        for (uint256 i = 0; i < g.length; i++) {
            require(g[i].code.length > 0, "V2 factory has no code");
        }
        require(V4_POOL_MANAGER.code.length > 0, "V4 PoolManager has no code");
        require(LFJ_LB_ROUTER.code.length > 0 && LFJ_LB_FACTORY.code.length > 0, "LB router/factory has no code");
    }
}
