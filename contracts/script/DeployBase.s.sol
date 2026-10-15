// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AlignedStackDeploy} from "./lib/AlignedStackDeploy.sol";
import {ChordV3Adapter, ChordV2Adapter, ChordV4Adapter} from "../src/chord/ChordAdapters.sol";
import {UniV3AnyForkAdapter} from "../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2TaxSafeAdapter} from "../src/adapters/UniV2TaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice NullTerminal core stack + adapter set on **Base (8453)** — docs/base-contracts-deploy.md.
/// @dev PREPARED, NOT BROADCAST (2026-09-30). Venue facts: docs/base-tape.md (recon 2026-09-30, head
///      51,992,303); every factory below was re-probed on-chain for its registry SHAPE before being
///      pinned (the flavor trap: a factory whose shape the adapter does not probe quotes fine and
///      reverts at execution). EIP-1559 chain — NO `--legacy`.
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployBase.s.sol \
///          --rpc-url "$BASE_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      Proxies land on 0x6Cf25d2a… / 0x1B1Fee89… / 0x6C662296… only from 0x0f11…4f79 at nonce 0
///      (`AlignedStackDeploy._preflight` refuses anything else).
contract DeployBaseScript is AlignedStackDeploy {
    // ── tokens ───────────────────────────────────────────────────────────────────────────────────
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // OP-stack WETH9 predeploy
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant USDBC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address internal constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // ── V3 family (UniV3AnyForkAdapter) — registry SHAPE probed per factory 2026-09-30 ────────────
    // Why AnyFork and not UniV3GenericAdapter: three of the pinned factories are Aerodrome Slipstream,
    // whose registry is `getPool(address,address,int24 tickSpacing)` (0x28af8d0b) — the uint24 probe
    // (0x1698ee82) REVERTS on them (measured on all three). UniV3GenericAdapter would quote them and
    // revert PoolNotCanonical at execution; AnyFork's third lane reads the pool's tickSpacing() and
    // asks the factory. Slipstream #3 + #1 are Base's #2 and #4 venues (~$635M/24h together).
    //                                                    shape            24h USD (recon, lower bound)
    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD; // getPool(uint24)  $389M
    address internal constant SLIPSTREAM_3_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef; // getPool(int24)  $458M
    address internal constant SLIPSTREAM_1_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A; // getPool(int24)  $177M
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865; // getPool(uint24)  $124M
    address internal constant SLIPSTREAM_2_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a; // getPool(int24)  $7.9M
    address internal constant QUICKSWAP_V4_FACTORY = 0xC5396866754799B9720125B104AE01d935Ab9C7b; // poolByPair (Algebra Integral) $2.9M
    address internal constant HYDREX_FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E; // poolByPair (Algebra Integral) $2.2M
    // NOT pinned: Solidly V3 0x70fe4a44… (pool fee() reverts — different ABI; $11.5M is one $33k-TVL
    // USDT/USDC pool), Sushi V3 / Alien Base V3 / BaseSwap V3 (<$0.6M/24h each).

    // ── V2 (UniV2TaxSafeAdapter) ─────────────────────────────────────────────────────────────────
    // TaxSafe, not Generic: Base's #1 Uniswap V2 pair is TIBBIR/VIRTUAL (Virtuals agent token, 1 % buy
    // AND 1 % sell tax read on-chain: projectBuyTaxBasisPoints = projectSellTaxBasisPoints = 100). The
    // generic adapter prices off amountIn and reverts `UniswapV2: K` on every taxed sell (Arc lesson).
    address internal constant UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6; // getPair(a,a) $10M
    // NOT pinned (the adapter cannot serve them correctly):
    //   Aerodrome V2 0x420DD381… ($8.5M) — registry is getPool(address,address,bool); getPair(a,a,bool)
    //     REVERTS (probed), so both adapter shapes fail provenance. Needs its own adapter.
    //   PancakeSwap V2 0x02a84c1b… ($0.6M) — 0.25 % fee; the adapter hardcodes 997/1000 (under-pays 5 bps).

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    // NOT served: PancakeSwap Infinity CL 0xa0ffb9c1… (vault-based ABI, extra protocolFee; $10.8M).

    function chainIdExpected() public pure override returns (uint256) {
        return 8453;
    }

    function chainName() public pure override returns (string memory) {
        return "Base (8453)";
    }

    function wrappedNative() public pure override returns (address) {
        return WETH;
    }

    function v3Factories() public pure returns (address[] memory f) {
        // Order = gas only (each provenance lane walks the list and stops at the first match).
        f = new address[](7);
        f[0] = UNISWAP_V3_FACTORY;
        f[1] = SLIPSTREAM_3_FACTORY;
        f[2] = SLIPSTREAM_1_FACTORY;
        f[3] = PANCAKE_V3_FACTORY;
        f[4] = SLIPSTREAM_2_FACTORY;
        f[5] = QUICKSWAP_V4_FACTORY;
        f[6] = HYDREX_FACTORY;
    }

    /// @dev ALL ZERO = registry lane for every factory (factory.getPool / poolByPair / getPool(int24)).
    ///      No creation-code hash is pinned: a wrong hash bricks a venue silently, and the registry is
    ///      authoritative anyway because the factory itself is pinned.
    function v3InitCodeHashes() public pure returns (bytes32[] memory h) {
        h = new bytes32[](7);
    }

    /// @dev EMPTY on purpose. Candidate creation tiers only rescue a fee-keyed pool whose live fee() is
    ///      not its creation key (Monad PangolinV3). Every pinned factory here is static-fee (Uniswap /
    ///      PCS: fee() IS the key), pair-keyed (Algebra, pass 1) or tickSpacing-keyed (Slipstream, pass
    ///      3 — its fee() is dynamic, e.g. 325 / 624 on WETH/USDC). Each candidate would cost one
    ///      staticcall PER FACTORY on every Slipstream swap — Base's busiest path — for no match.
    ///      BaseForkTest proves every pinned venue authenticates with this empty list.
    function v3FeeTiers() public pure returns (uint24[] memory t) {
        t = new uint24[](0);
    }

    function v2Factories() public pure returns (address[] memory f) {
        f = new address[](1);
        f[0] = UNISWAP_V2_FACTORY;
    }

    function _deployV3Adapter(address router) internal override returns (address) {
        return address(new ChordV3Adapter(router, v3Factories(), v3InitCodeHashes(), v3FeeTiers()));
    }

    function _deployOtherAdapters(address router)
        internal
        override
        returns (address[] memory adapters, string[] memory names)
    {
        adapters = new address[](2);
        names = new string[](2);
        adapters[0] = address(new ChordV2Adapter(router, v2Factories()));
        names[0] = "ChordV2Adapter";
        adapters[1] = address(new ChordV4Adapter(router, V4_POOL_MANAGER, WETH));
        names[1] = "ChordV4Adapter";
    }

    /// @dev OWNER GATE — docs/fee-tiers.md "stable" + "major" rows (0 bps on the OUTPUT token). Arc
    ///      zeroed its two stables; Monad zeroes stables + WMON/WETH/WBTC/cbBTC. Edit before broadcast
    ///      or push `setTokenFeeBpsBatch` later — no redeploy needed.
    function zeroFeeTokens() public pure override returns (address[] memory t) {
        t = new address[](6);
        t[0] = USDC;
        t[1] = USDT;
        t[2] = USDBC;
        t[3] = EURC;
        t[4] = WETH; // also covers native-ETH output (the router charges on wmon)
        t[5] = CBBTC;
    }

    function _preflightChain() internal view override {
        address[] memory f = v3Factories();
        for (uint256 i = 0; i < f.length; i++) {
            require(f[i].code.length > 0, "V3 factory has no code");
        }
        require(UNISWAP_V2_FACTORY.code.length > 0, "V2 factory has no code");
        require(V4_POOL_MANAGER.code.length > 0, "V4 PoolManager has no code");
    }
}
