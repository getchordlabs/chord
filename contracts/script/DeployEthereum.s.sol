// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AlignedStackDeploy} from "./lib/AlignedStackDeploy.sol";
import {ChordV3Adapter, ChordV2Adapter, ChordV4Adapter} from "../src/chord/ChordAdapters.sol";

/// @notice Chord core stack + adapter set on **Ethereum mainnet (chain 1)** — docs/ethereum-contracts-deploy.md (board #279).
/// @dev PREPARED, NOT BROADCAST (2026-10-15). Same body, nonce map and Chord-named contracts as Base / BNB / Arbitrum
///      (`AlignedStackDeploy`), so every contract lands on the SAME address number as on Base and Arbitrum (same deployer,
///      same nonces) — the bytecode differs where the constructor arguments do (factory lists, PoolManager, WETH).
///      Every factory below was read on-chain for code + registry shape on 2026-10-15. EIP-1559 — NO `--legacy`; `--slow`
///      so each transaction is estimated after the previous one is mined (runbook §0):
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployEthereum.s.sol \
///          --rpc-url "$ETH_RPC_URL" --broadcast --slow --gas-estimate-multiplier 200
///      Proxies land on 0x6Cf25d2a… / 0x1B1Fee89… / 0x6C662296… only from 0x0f11…4f79 at nonce 0
///      (`AlignedStackDeploy._preflight` refuses anything else: chain id, deployer, nonce, empty proxy addresses).
///      Metric v1 is NOT deployed on chain 1 (its volatile pools answer FeedStalled off-chain — runbook §0).
contract DeployEthereumScript is AlignedStackDeploy {
    // ── tokens (symbol / decimals read on-chain 2026-10-15) ──────────────────────────────────────
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18, WETH9 (deposit/withdraw)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6
    // USDT: transfer / transferFrom / approve return NOTHING, and approve(non-zero) reverts while an allowance is
    // non-zero. TransferLib (router + every adapter) accepts an empty return; no adapter in this set approves USDT
    // (V3 / V2 / V4 push or pay in the callback).
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8

    // ── V3 family (ChordV3Adapter = UniV3AnyForkAdapter) — all three answer getPool(a,a,uint24) ─────
    // Static-fee, fee-keyed registries: provenance authenticates every pool with the pool's own fee() through
    // factory.getPool. Order = gas only (each lane walks the list and stops at the first match): Uniswap V3 first
    // (WETH/USDC 0.05 % 0x88e6A0c2… holds 9,725 WETH, 0.3 % 0x8ad599c3… 13,531 WETH), PancakeSwap V3 (WETH/USDC 0.01 %
    // 0x1445F32D… 119 WETH), SushiSwap V3 (WETH/USDC 0.3 % 0x763d3b72… 428 WETH).
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    // PancakeSwap V3 pools are CREATE2'd by its PoolDeployer 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9
    // (`factory.poolDeployer()`, read 2026-10-15), but they answer factory() = the FACTORY, and the registry lane
    // (factory.getPool) is what authenticates them, so the deployer is not pinned. Callback = pancakeV3SwapCallback →
    // the adapter's fallback (same as Base / BNB / Arbitrum `pancake_v3_via_generic`).
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant SUSHI_V3_FACTORY = 0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F;
    // NOT pinned (not in the engine's first venue set; the list is immutable, so adding one later = a NEW adapter, or
    // edit this list BEFORE broadcasting — same nonce slot): the other V3-shaped factories on the tape (0x44b7fbd4…,
    // 0x00a38533…), Solidly V3, Kyber Elastic.

    // ── V2 (ChordV2Adapter = UniV2TaxSafeAdapter, 0.3 %) ─────────────────────────────────────────
    // Both factories charge 0.3 %: their Router02s' getAmountOut(1e6, 1e9, 1e9) = 996006 = the 997/1000 formula the
    // adapter hardcodes (read 2026-10-15: Uniswap V2 Router02 0x7a250d56…, SushiSwap Router 0xd9e1cE17…; the fork test
    // asserts fill == Router02.getAmountsOut both ways). The adapter takes a factory LIST, so SushiSwap V2 rides the
    // same contract — no second V2 deployment. Uniswap's protocol fee (feeTo) mints LP shares and leaves swap math alone.
    address internal constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // getPair(a,a)
    address internal constant SUSHI_V2_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac; // getPair(a,a)
    // NOT pinned: PancakeSwap V2 on Ethereum (0x1097053F…, 0.25 % — a fee per factory needs ChordV2FeeAdapter) and the
    // smaller V2 forks of the tape (ShibaSwap, Fraxswap, DefiSwap …).

    // ── V4 (ChordV4Adapter = UniswapV4Adapter) ───────────────────────────────────────────────────
    // Pools quote a protocol fee on top of the LP fee (ETH/USDC 0.05 % slot0.protocolFee = 0x07D07D = 125 pips each
    // way, read 2026-10-15) — that is the engine's quote math, the adapter just swaps.
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function chainIdExpected() public pure override returns (uint256) {
        return 1;
    }

    function chainName() public pure override returns (string memory) {
        return "Ethereum (1)";
    }

    function wrappedNative() public pure override returns (address) {
        return WETH;
    }

    /// @dev Owner 2026-10-02: one 5 bps default on every chain (docs/fee-tiers.md). Like Arbitrum, Ethereum starts at 5.
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
    ///      always matches; candidate tiers would only add a staticcall per factory to a miss.
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

    /// @dev docs/fee-tiers.md "stable" + "major" rows (0 bps on the OUTPUT token), by ADDRESS. Change later with
    ///      `setTokenFeeBpsBatch` (no redeploy).
    function zeroFeeTokens() public pure override returns (address[] memory t) {
        t = new address[](5);
        t[0] = USDC;
        t[1] = USDT;
        t[2] = DAI;
        t[3] = WETH; // also covers native-ETH output (the router charges on wmon)
        t[4] = WBTC;
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
