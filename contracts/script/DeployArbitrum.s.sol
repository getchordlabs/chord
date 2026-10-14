// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AlignedStackDeploy} from "./lib/AlignedStackDeploy.sol";
import {ChordV3Adapter, ChordV2Adapter, ChordV4Adapter} from "../src/chord/ChordAdapters.sol";

/// @notice Chord core stack + adapter set on **Arbitrum One (42161)** — docs/arbitrum-contracts-deploy.md.
/// @dev PREPARED, NOT BROADCAST (2026-10-14). Same body, nonce map and Chord-named contracts as Base / BNB
///      (`AlignedStackDeploy`), so every contract lands on the SAME address number as on Base (same deployer, same
///      nonces) — the bytecode differs where the constructor arguments do (factory lists, PoolManager, WETH).
///      Every factory below was read on-chain for code + registry shape on 2026-10-14. Nitro / EIP-1559 — NO `--legacy`:
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployArbitrum.s.sol \
///          --rpc-url "$ARBITRUM_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      Proxies land on 0x6Cf25d2a… / 0x1B1Fee89… / 0x6C662296… only from 0x0f11…4f79 at nonce 0
///      (`AlignedStackDeploy._preflight` refuses anything else: chain id, deployer, nonce, empty proxy addresses).
///      Metric v1 is a follow-up (script/DeployMetricV1Adapter.s.sol), not part of this run — the nonce map stays Base's.
contract DeployArbitrumScript is AlignedStackDeploy {
    // ── tokens (decimals read on-chain 2026-10-14) ───────────────────────────────────────────────
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // 18, aeWETH (deposit/withdraw)
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // 6, native Circle USDC
    address internal constant USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // 6, USD₮0
    address internal constant USDCE = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8; // 6, bridged USDC.e (symbol "USDC")
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f; // 8
    address internal constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // 18

    // ── V3 family (ChordV3Adapter = UniV3AnyForkAdapter) — all three answer getPool(a,a,uint24) ─────
    // Static-fee, fee-keyed registries: provenance authenticates every pool in pass 2 with the pool's own fee()
    // (fork test: Uniswap 0.05 %, PancakeSwap 0.01 % + 0.05 %, SushiSwap 0.05 %). Order = gas only: each
    // provenance lane walks the list and stops at the first match; Uniswap V3 is the deepest venue.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    // PancakeSwap V3 pools are CREATE2'd by its PoolDeployer 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9, not the
    // factory; the registry lane (factory.getPool) is what authenticates them, so the deployer is not pinned.
    // Callback = pancakeV3SwapCallback → the adapter's fallback (same as Base / BNB `pancake_v3_via_generic`).
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant SUSHI_V3_FACTORY = 0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e;
    // NOT pinned (not in the engine's first venue set; the list is immutable, so adding one later = a NEW adapter,
    // or edit this list BEFORE broadcasting — same nonce slot): Camelot V3 (Algebra; its factory answers poolByPair,
    // so pass 1 would authenticate it — not fork-tested; ArbitrumForkTest proves it is REFUSED today), Ramses, other forks.

    // ── V2 (ChordV2Adapter = UniV2TaxSafeAdapter, 0.3 %) ─────────────────────────────────────────
    // Both factories charge 0.3 %: their routers' getAmountOut(1e6, 1e9, 1e9) = 996006 = the 997/1000 formula the
    // adapter hardcodes (read 2026-10-14; the fork test asserts fill == Router02.getAmountsOut both ways). The
    // adapter takes a factory LIST, so SushiSwap V2 rides the same contract — no second V2 deployment.
    address internal constant UNISWAP_V2_FACTORY = 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9; // getPair(a,a)
    address internal constant SUSHI_V2_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4; // getPair(a,a)
    // NOT pinned: Camelot V2 (per-pair token0FeePercent / token1FeePercent + a stableSwap flag, read on its WETH/USDC
    // pair 2026-10-14 — a fee per factory cannot express it).

    // ── V4 (ChordV4Adapter = UniswapV4Adapter) ───────────────────────────────────────────────────
    address internal constant V4_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    function chainIdExpected() public pure override returns (uint256) {
        return 42161;
    }

    function chainName() public pure override returns (string memory) {
        return "Arbitrum One (42161)";
    }

    function wrappedNative() public pure override returns (address) {
        return WETH;
    }

    /// @dev Owner 2026-10-02: one 5 bps default on every chain (docs/fee-tiers.md). Base / BNB / Avalanche were
    ///      initialised at 25 and lowered by a later `setFeeBps(5)`; Arbitrum starts at 5.
    function defaultFeeBps() public pure override returns (uint16) {
        return 5;
    }

    function v3Factories() public pure returns (address[] memory f) {
        f = new address[](3);
        f[0] = UNISWAP_V3_FACTORY;
        f[1] = PANCAKE_V3_FACTORY;
        f[2] = SUSHI_V3_FACTORY;
    }

    /// @dev ALL ZERO = registry lane for every factory (factory.getPool). No creation-code hash is pinned: a wrong
    ///      hash bricks a venue silently, PancakeSwap's pools are not even CREATE2'd by its factory, and the registry
    ///      is authoritative anyway because the factory itself is pinned.
    function v3InitCodeHashes() public pure returns (bytes32[] memory h) {
        h = new bytes32[](3);
    }

    /// @dev EMPTY on purpose: all three factories are static-fee (fee() IS the registry key), so the live-fee probe
    ///      of pass 2 always matches; candidate tiers would only add a staticcall per factory to a miss.
    function v3FeeTiers() public pure returns (uint24[] memory t) {
        t = new uint24[](0);
    }

    function v2Factories() public pure returns (address[] memory f) {
        f = new address[](2);
        f[0] = UNISWAP_V2_FACTORY;
        f[1] = SUSHI_V2_FACTORY;
    }

    function _deployV3Adapter(address router) internal override returns (address) {
        return address(new ChordV3Adapter(router, v3Factories(), v3InitCodeHashes(), v3FeeTiers())); // nonce 5
    }

    function _deployOtherAdapters(address router)
        internal
        override
        returns (address[] memory adapters, string[] memory names)
    {
        adapters = new address[](2);
        names = new string[](2);
        adapters[0] = address(new ChordV2Adapter(router, v2Factories())); // nonce 9
        names[0] = "ChordV2Adapter";
        adapters[1] = address(new ChordV4Adapter(router, V4_POOL_MANAGER, WETH)); // nonce 10
        names[1] = "ChordV4Adapter";
    }

    /// @dev docs/fee-tiers.md "stable" + "major" rows (0 bps on the OUTPUT token), by ADDRESS — USDC.e also calls
    ///      itself "USDC". Change later with `setTokenFeeBpsBatch` (no redeploy).
    function zeroFeeTokens() public pure override returns (address[] memory t) {
        t = new address[](6);
        t[0] = USDC;
        t[1] = USDT0;
        t[2] = USDCE;
        t[3] = DAI;
        t[4] = WETH; // also covers native-ETH output (the router charges on wmon)
        t[5] = WBTC;
    }

    function _preflightChain() internal view override {
        address[] memory f = v3Factories();
        for (uint256 i = 0; i < f.length; i++) {
            require(f[i].code.length > 0, "V3 factory has no code");
        }
        address[] memory f2 = v2Factories();
        for (uint256 i = 0; i < f2.length; i++) {
            require(f2[i].code.length > 0, "V2 factory has no code");
        }
        require(V4_POOL_MANAGER.code.length > 0, "V4 PoolManager has no code");
        address[] memory z = zeroFeeTokens();
        for (uint256 i = 0; i < z.length; i++) {
            require(z[i].code.length > 0, "zero-fee token has no code");
        }
    }
}
