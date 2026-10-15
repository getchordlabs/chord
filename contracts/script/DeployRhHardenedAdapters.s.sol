// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {UniV3AnyForkAdapter} from "../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2GenericAdapter} from "../src/adapters/UniV2GenericAdapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {MetricAdapter} from "../src/adapters/MetricAdapter.sol";
import {AlgebraAdapter} from "../src/adapters/AlgebraAdapter.sol";

/// @dev Minimal views on the LIVE RH NullRouter proxy. Deliberately not the full `NullRouter` type:
///      this script must never be able to CALL the router, only read the two fields that prove the
///      adapters are being pinned to the right deployment.
interface INullRouterView {
    function registry() external view returns (address);
    function wmon() external view returns (address);
}

/// @dev The one thing every H1-hardened adapter has in common (`BaseAdapter`): the NullRouter it
///      pins as its immutable and the ONLY caller its `swap()` accepts. Reading it back is how this
///      script proves the pin actually landed, without caring which adapter it is looking at.
interface IHardenedAdapter {
    function NULL_ROUTER() external view returns (address);
}

/// @title DeployRhHardenedAdapters
/// @notice Deploys the H1-hardened adapter set on **Robinhood Chain (4663)** and registers it in the
///         EXISTING, LIVE `AdapterRegistry` — it does NOT stand up a new core stack.
///
/// @dev WHY THIS SCRIPT EXISTS (and why it is not `DeployRH.s.sol`)
///      `script/DeployRH.s.sol` is greenfield: it deploys a fresh AdapterRegistry + NullRouter +
///      FeeCollector. RH already has all three, live, owned by the deployer EOA. What RH never got is
///      the 2026-08-05 **H1 hardening** that Monad received the same day: every one of its five
///      approved adapters runs pre-H1 bytecode with NO `onlyRouter` entrypoint gate and no pool
///      provenance, i.e. `swap()` is world-callable and its destination comes from caller-supplied
///      `extraData`. Verified on-chain 2026-08-05 (chainId asserted 4663 FIRST — see "RPC" below):
///      the `NotRouter` selector `0x91655201` is absent from all five runtimes.
///
///      Adapters are IMMUTABLE, so this cannot be an upgrade: it is fresh deploys + registry
///      approval. Per the DEX rule in CLAUDE.md the OLD adapters are deliberately NOT removed here —
///      `addAdapter(new)` → **mainnet swap verified BOTH DIRECTIONS** → `removeAdapter(old)`, one
///      venue at a time. This script performs only the first of those three steps.
///
///      HONEST SIZING: at time of writing all five RH adapters hold zero balance, the RH router has
///      emitted ~30 Swap events (~$438) in its life, and lifetime RH fee revenue is ~$0.54. This is
///      a real missing control on a surface that is currently carrying almost no money — which is
///      exactly why it is cheap to fix now. It is not an emergency; it is also not optional.
///
///      ── USAGE ──────────────────────────────────────────────────────────────────────────────────
///        forge script script/DeployRhHardenedAdapters.s.sol \
///          --rpc-url https://rpc.mainnet.chain.robinhood.com \
///          --broadcast --gas-estimate-multiplier 200
///
///      `--gas-estimate-multiplier 200` is NOT optional. Deploying a contract and calling
///      `addAdapter` on it inside the SAME forge run repeatedly OOGs on gas estimation, because the
///      estimate for the registry call is computed against a state where the adapter does not exist
///      yet. This has burned real deploys (CLAUDE.md "Monad deploy gotchas"); the documented
///      fallback is to re-issue the failed `addAdapter` with `cast send`.
///
///      RH is an Arbitrum-stack chain: EIP-1559 works, do NOT pass `--legacy` (that flag is a
///      Monad-only requirement and passing it here is how a Monad habit leaks onto 4663).
///
///      Verify with **Blockscout**, not Sourcify:
///        forge verify-contract <addr> <Contract> --verifier blockscout \
///          --verifier-url https://robinhoodchain.blockscout.com/api
///
///      RPC: 4663 is reachable from the VPS docker network only (`http://moltnode:3000/robinhood`).
///      Whatever you point at it, **assert `eth_chainId == 0x1237` before believing any result** — a
///      connection failure to this endpoint is indistinguishable from a negative on-chain answer,
///      and reading one as the other cost two wrong conclusions in a single day.
///
///      ── THREE LESSONS BAKED INTO THE CONSTANTS BELOW ───────────────────────────────────────────
///      1. **Init-code hashes: pass `bytes32(0)` unless the hash is VERIFIED.** Zero selects the
///         factory's own on-chain registry (`getPool` / `poolByPair` / `getPair`), which cannot be
///         wrong because the factory is pinned either way. A WRONG hash bricks the venue SILENTLY:
///         quotes keep working (they never touch the adapter) and every swap reverts at execution.
///         No RH fork's creation-code hash is verified anywhere in this repo, so every entry in
///         `_rhV3InitCodeHashes()` is zero, on purpose. Do not "optimise away" the staticcall.
///      2. **FLAVOR TRAP — the venue's ABI decides which contract is correct, and only bytecode can
///         tell you which ABI.** On Monad, PancakeSwap's router turned out to be SwapRouter **v1**
///         (`exactInputSingle` = `0x414bf389`) rather than SwapRouter02 (`0x04e45aaf`); the wrong
///         adapter deployed, registered, quoted correctly, and then reverted bare-`0x` on execution.
///         Probe before wiring ANY V3-family venue: `cast code <router> | grep -c <selector>`.
///         The same trap is live on 4663 and is why the lists below are not simply copied from
///         chain.rs — see the per-list notes. Three V3 forks and one V2 fork on this chain answer a
///         DIFFERENT registry shape than their siblings.
///      3. **Never copy a Monad constant.** Every address here was recovered from
///         `packages/engine/src/chain.rs` `robinhood()` and/or read back off the LIVE 4663
///         deployment, then re-checked against the other source. The two chains deliberately share
///         the router/registry ADDRESSES (nonce-aligned CREATE from the same EOA) but nothing else,
///         which makes a copied constant look plausible right up until it moves money.
contract DeployRhHardenedAdaptersScript is Script {
    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // LIVE RH (4663) CORE — read back on-chain 2026-08-05 after asserting chainId 0x1237.
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The NullRouter PROXY every adapter below pins as its immutable `NULL_ROUTER`.
    /// @dev Same address as Monad's router — NOT a copy-paste bug: both chains were deployed by the
    ///      same EOA at aligned nonces. Verified as the RH deployment by its own state, which is what
    ///      `_preflight()` re-checks at run time rather than trusting this comment:
    ///        registry()     = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f (the registry below)
    ///        wmon()         = 0x0Bd7D308…AD73 (WETH9 on 4663 — Monad's router answers WMON)
    ///        owner()        = 0x0f1171209dAD379AF0E486f2c77D275D6E0a4f79 (deployer EOA)
    ///        impl (EIP1967) = 0x3D3C7C44CF1657e72B574f768B40A022B863e464 since 2026-08-21 (H2/M1/
    ///                         L2/L3/L5 source, UpgradeNullRouter.s.sol, Blockscout-verified). Before
    ///                         that it was 0x1cd8CeED… — the PRE-H2 router, byte-identical to the
    ///                         b654976 build; RH ran it for 16 days after Monad's 08-05 upgrade.
    ///                         FeeCollector went 0xd55fe37e… → 0x34DA6E05… the same day (feeManager
    ///                         role + L1 sweep). Out of scope here (adapters only).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    /// @notice The LIVE RH AdapterRegistry. Owner is the deployer EOA, so `addAdapter` is callable.
    /// @dev Held exactly five adapters when this script was written, all pre-H1:
    ///        0x1C91d6b9…24f6 UniV3Generic · 0x9621851A…526E UniV2Direct · 0x4e48D8bE…07b1 V4
    ///        0x77dacA68…4E41 Metric       · 0xF5450E7f…ac26 Algebra
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    /// @notice Wrapped native on 4663 — WETH9, not WMON. chain.rs `wrapped_native`, and confirmed by
    ///         BOTH the live router's `wmon()` and the live V4 adapter's `WMON()` immutable.
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // VENUE INFRA — chain.rs `robinhood()`, each cross-checked against the LIVE pre-H1 adapter's own
    // public immutable where one exists (the pre-H1 V2/V3/Algebra adapters have no immutables at all,
    // so for those the engine config is the only source and was re-probed on-chain instead).
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Uniswap V4 PoolManager on 4663. chain.rs `v4_pool_manager` == live adapter
    ///         0x4e48D8bE…07b1 `POOL_MANAGER()`. Two independent sources agree.
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Metric OMM (legacy generation) shared SwapRouter. chain.rs `metric_router` == live
    ///         adapter 0x77dacA68…4E41 `ROUTER()`. Two independent sources agree.
    address constant METRIC_ROUTER = 0x1CA647e4F0E7557D3B1e7347bD70083E2a59b844;

    /// @notice Algebra factory on 4663 (chain.rs `atlantis_factory`). The live pre-H1 AlgebraAdapter
    ///         has NO immutable to cross-check against, so this was verified directly: the factory's
    ///         `poolByPair(WETH9, USDG)` returns 0x536a7b19…6674 in BOTH token orderings, which is
    ///         precisely the registry lane `AlgebraAdapter._requireRegisteredPool` relies on.
    /// @dev A SECOND Algebra factory exists on this chain (0x28a57a40…304e) and chain.rs deliberately
    ///      does not route it (~$1k of anchor-priced depth). It is NOT added here: `AlgebraAdapter`
    ///      pins ONE factory, so routing it would be a second deployment plus an engine change.
    address constant ALGEBRA_FACTORY = 0x21Fd9aB06cc927E66013e89b045c26b3eDE7bB20;

    /// @notice Metric OMM factory — the provenance source for the allowlist in `_rhMetricPools()`.
    ///         Not a constructor argument (MetricAdapter pins the ROUTER, not the factory); recorded
    ///         because it is where the pool list came from and where a refresh must come from.
    address constant METRIC_FACTORY = 0xe22F9fc0f04486dE25ed6CF1800a4a47aFD82e0C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain 4663");
        _preflight(deployer);

        vm.startBroadcast(deployerPrivateKey);

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);

        // ── 1. UniV3AnyForkAdapter — every V3-family fork on 4663, BOTH registry shapes ──────────
        UniV3AnyForkAdapter v3 = new UniV3AnyForkAdapter(
            NULL_ROUTER, _rhV3Factories(), _rhV3InitCodeHashes(), _rhV3FeeTiers()
        );
        registry.addAdapter(address(v3));

        // ── 2. UniV2GenericAdapter — the MULTI-factory V2 adapter ─────────────────────────────────
        //      `UniV2DirectAdapter` pins ONE factory. RH routes seven pinnable V2 forks through a
        //      single `adapter_univ2` config field, so the single-factory contract would reject every
        //      pool but one fork's. This is the contract that exists for that.
        UniV2GenericAdapter v2 = new UniV2GenericAdapter(NULL_ROUTER, _rhV2Factories());
        registry.addAdapter(address(v2));

        // ── 3. UniswapV4Adapter — PoolManager + wrapped native ────────────────────────────────────
        UniswapV4Adapter v4 = new UniswapV4Adapter(NULL_ROUTER, V4_POOL_MANAGER, WETH9);
        registry.addAdapter(address(v4));

        // ── 4. MetricAdapter — shared router + IMMUTABLE pool allowlist ───────────────────────────
        MetricAdapter metric = new MetricAdapter(NULL_ROUTER, METRIC_ROUTER, _rhMetricPools());
        registry.addAdapter(address(metric));

        // ── 5. AlgebraAdapter — one pinned Algebra factory ────────────────────────────────────────
        AlgebraAdapter algebra = new AlgebraAdapter(NULL_ROUTER, ALGEBRA_FACTORY);
        registry.addAdapter(address(algebra));

        vm.stopBroadcast();

        _postflight(registry, address(v3), address(v2), address(v4), address(metric), address(algebra));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // Preflight / postflight — cheap asserts that catch the mistakes that actually happen
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Everything here fails BEFORE any gas is spent. The pin is the whole point of H1: an
    ///      adapter whose `NULL_ROUTER` is the wrong address is either bricked (nothing can call it)
    ///      or, if it were pointed at some other live router, gated to the wrong caller entirely.
    function _preflight(address deployer) internal view {
        require(NULL_ROUTER.code.length > 0, "NULL_ROUTER has no code on this chain");
        require(ADAPTER_REGISTRY.code.length > 0, "ADAPTER_REGISTRY has no code on this chain");

        // The router must point at the registry we are about to write to — this is what proves the
        // two constants belong to the SAME deployment, on THIS chain.
        require(
            INullRouterView(NULL_ROUTER).registry() == ADAPTER_REGISTRY,
            "router.registry() != ADAPTER_REGISTRY - constants are from different deployments"
        );
        // Wrapped native is the one constant that differs between the chains while the router and
        // registry addresses do NOT, so it is the sharpest cheap test for "am I on Monad by mistake".
        require(INullRouterView(NULL_ROUTER).wmon() == WETH9, "router.wmon() != WETH9 - wrong chain?");
        // addAdapter is onlyOwner: without this the deploys succeed and every registration reverts.
        require(
            AdapterRegistry(ADAPTER_REGISTRY).owner() == deployer,
            "deployer is not the AdapterRegistry owner - addAdapter would revert"
        );

        require(V4_POOL_MANAGER.code.length > 0, "V4_POOL_MANAGER has no code");
        require(METRIC_ROUTER.code.length > 0, "METRIC_ROUTER has no code");
        require(ALGEBRA_FACTORY.code.length > 0, "ALGEBRA_FACTORY has no code");
    }

    /// @dev Reads the pin back off each freshly deployed adapter and confirms the registry accepted
    ///      it, then prints the follow-up the operator still owes. `removeAdapter` for the old five
    ///      is NOT done here and must not be: the rule is add → both-ways mainnet swap → remove.
    function _postflight(
        AdapterRegistry registry,
        address v3,
        address v2,
        address v4,
        address metric,
        address algebra
    ) internal view {
        address[5] memory deployed = [v3, v2, v4, metric, algebra];
        for (uint256 i = 0; i < deployed.length; i++) {
            require(registry.isApproved(deployed[i]), "adapter not approved after addAdapter");
            require(
                IHardenedAdapter(deployed[i]).NULL_ROUTER() == NULL_ROUTER,
                "adapter NULL_ROUTER pin mismatch"
            );
        }

        console2.log("=== RH (4663) H1-hardened adapter set: DEPLOYED + APPROVED ===");
        console2.log("UniV3AnyForkAdapter:", v3);
        console2.log("UniV2GenericAdapter:", v2);
        console2.log("UniswapV4Adapter:   ", v4);
        console2.log("MetricAdapter:      ", metric);
        console2.log("AlgebraAdapter:     ", algebra);
        console2.log("");
        console2.log("STILL OWED, in this order, ONE VENUE AT A TIME:");
        console2.log(" 1. point engine chain.rs robinhood() adapter_* at the NEW addresses");
        console2.log(" 2. mainnet swap BOTH DIRECTIONS on each venue");
        console2.log(" 3. only then removeAdapter() the pre-H1 five:");
        console2.log("    0x1C91d6b9300DC62E587B4d24C27B343292A524f6  (UniV3Generic, pre-H1)");
        console2.log("    0x9621851A32A33e68b235e00D51c104C9A8A0526E  (UniV2Direct,  pre-H1)");
        console2.log("    0x4e48D8bEDB4A781493e6193776FDa37e57Ce07b1  (UniswapV4,    pre-H1)");
        console2.log("    0x77dacA688B0877dD3eAc3A1895f598c4907D4E41  (Metric,       pre-H1)");
        console2.log("    0xF5450E7f97151eA66258C9318EA1286c80bEac26  (Algebra,      pre-H1)");
        console2.log(" 4. verify all five on Blockscout (NOT Sourcify) - see contract NatSpec");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // V3 family
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Every V3-family factory the engine routes on 4663 — `uniswap_v3_factory` +
    ///      `RH_GENERIC_V3_FORKS` + `RH_SLIPSTREAM_FORKS` from packages/engine/src/chain.rs, kept in
    ///      the SAME ORDER except that the three provenance-dead forks are moved to the end (order is
    ///      pure gas: `_requireCanonicalPool` walks this list per lane and returns on first match, so
    ///      the deepest venues belong first).
    ///
    ///      ⚠️ **TODO(owner) — THREE FORKS CANNOT BE AUTHENTICATED BY THIS ADAPTER.** Flavor-probed
    ///      on-chain 2026-08-05 (chainId asserted; one real pool per factory, read its token0/token1/
    ///      fee()/tickSpacing(), then asked the factory to name it back):
    ///
    ///        graildex_v3  0x46c695d1…2aa5  sample 0xc20623952ad4894cc4b053488808685eff6e0d4f
    ///        ramses_v3    0xE0c4ceb9…54A8  sample 0x8b0e1a2c3fe256df1178d98b058f2044f1bf12f3
    ///        up_v3        0x1ac9dB4a…B7F3  sample 0x7b8187b1f073e92860943317e4336e1357e357d6
    ///
    ///      All three answer **`getPool(address,address,int24 tickSpacing)`** (selector `0x28af8d0b`)
    ///      and NOT `getPool(address,address,uint24 fee)` (`0x1698ee82`) — Slipstream/Ramses lineage,
    ///      tickSpacing-keyed. `UniV3GenericAdapter` probes only the uint24 shape and `poolByPair`,
    ///      so their pools revert `PoolNotCanonical` at EXECUTION while quoting perfectly. That is
    ///      the exact silent-brick failure mode lesson (1) is about, arriving through the ABI rather
    ///      than through a bad hash. Note `graildex_v3` and `ramses_v3` still EMIT the Uniswap-shaped
    ///      `PoolCreated(a,a,uint24,int24,a)` event, so log-shape is not a safe proxy for lane — only
    ///      asking the factory to name a known pool back is.
    ///
    ///      A verified initCodeHash does NOT rescue them either: this adapter's CREATE2 salts are
    ///      `keccak(t0,t1)` and `keccak(t0,t1,uint24 fee)`, while these forks salt on tickSpacing.
    ///      They are listed anyway so this array stays a faithful mirror of chain.rs (a silent
    ///      omission is how a fork gets "re-added" later by someone diffing the two files); listing
    ///      them costs only staticcall gas on the failing path and grants no trust — a factory that
    ///      never returns a match can never authenticate anything.
    ///
    ///      RESOLVED 2026-08-05 — option (a). `UniV3AnyForkAdapter` (used above) is a superset of
    ///      `UniV3GenericAdapter` with a THIRD provenance lane that reads the pool's live
    ///      `tickSpacing()` and staticcalls `getPool(address,address,int24)`. Verified against the
    ///      live chain: up_v3 pool 0x851d1b03… (the very pool chain.rs cites as the KINDRA benchmark
    ///      fix) matches on the int24 lane and NOT on the uint24 lane. Mutation-tested — deleting the
    ///      lane turns exactly one test red, deleting provenance entirely turns four red.
    ///      Why a new contract instead of editing UniV3GenericAdapter: that source compiles the LIVE
    ///      Monad adapter 0x27ed74C9 (Sourcify exact_match) and one character costs it verification.
    ///      Tick spacing is read live with NO candidate list, deliberately unlike `feeTiers`: a
    ///      dynamic-fee fork can report a `fee()` it was not salted with (the PangolinV3 lesson), but
    ///      tick spacing is fixed at creation AND is the registry key itself. It fails closed.
    function _rhV3Factories() internal pure returns (address[] memory f) {
        f = new address[](13);
        // ── authenticated via getPool(address,address,uint24) — all probed 2026-08-05 ──
        f[0] = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // uniswap_v3 (chain.rs uniswap_v3_factory)
        f[1] = 0xEce6eCd61177336ea6Fb9b17937AC439D85EE20B; // giga_v3
        f[2] = 0x0Ec554F0BfF0Be6C99d1e95C8015bb0950f6A2C7; // swaphood_v3
        f[3] = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865; // pcs_v3
        f[4] = 0xd479E71C45aEB1E846A7B549c346D62fE77B39bA; // uniswap_v3_b
        f[5] = 0xEa561E058313B96011e5070Ca7d0f027A44E3748; // robinswap_v3
        f[6] = 0x8ed4510ab87Bb64E1Be0f54ae0c5534629257a44; // based_v3
        f[7] = 0xE51960f1B45f1C9FB6D166E6a884F866fC70433B; // sushiswap_v3
        f[8] = 0xcA8152ab363dC2F23BB30f6c6c2678028E7cF30a; // uniswap_v3_e
        f[9] = 0x869c5ae05AaE4fd8D6D63F35107f14e8260b8c33; // rh_v3_f
        // ── ⚠️ PROVENANCE-DEAD: tickSpacing-keyed registry, see TODO(owner) above ──
        f[10] = 0x46c695d1Eba2411824C22DF59b8F488493a72aa5; // graildex_v3  ⚠️ getPool(a,a,int24)
        f[11] = 0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8; // ramses_v3    ⚠️ getPool(a,a,int24)
        f[12] = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3; // up_v3        ⚠️ getPool(a,a,int24)
    }

    /// @dev Parallel to `_rhV3Factories()`. **ALL ZERO, deliberately** — zero selects the factory's
    ///      own on-chain registry, which cannot be wrong. Not one of these forks' pool creation-code
    ///      hashes is verified anywhere in this repo, and a guessed hash bricks the venue silently
    ///      (lesson 1 in the contract NatSpec). If a hash is ever VERIFIED — derived from the
    ///      factory's actual deployed pool bytecode and confirmed to reproduce a known pool address —
    ///      it may be pinned here to skip the staticcall. Until then: zero.
    function _rhV3InitCodeHashes() internal pure returns (bytes32[] memory h) {
        h = new bytes32[](13); // zero-initialised = registry lane for every factory
    }

    /// @dev Candidate CREATION fee tiers, probed only AFTER the pool's live `fee()` fails to key it —
    ///      the dynamic-fee case (a Monad PangolinV3 pool reports fee 10 but was registered at 2500).
    ///      Union of chain.rs `v3_fee_tiers` + `v3_fork_fee_tiers` for 4663.
    ///
    ///      Deliberately NOT extended with the non-canonical fees observed live on RH pools (5000 on
    ///      uniswap_v3_e, 9500 on graildex, 20000 on ramses): those are STATIC fees, already covered
    ///      by the live-`fee()` probe that runs first. Every extra tier here costs one staticcall PER
    ///      FACTORY on the non-matching path, so the list stays minimal. If a genuinely dynamic-fee
    ///      fork appears on 4663, its creation fee must be added here and the adapter redeployed.
    function _rhV3FeeTiers() internal pure returns (uint24[] memory t) {
        t = new uint24[](5);
        t[0] = 100;
        t[1] = 500;
        t[2] = 2500;
        t[3] = 3000;
        t[4] = 10000;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // V2 family
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev `RH_V2_FACTORIES` from chain.rs — **SEVEN of the eight**. Each was flavor-probed on-chain
    ///      2026-08-05 by taking a real pair from the factory (`allPairs()` / `PairCreated`), reading
    ///      its token0/token1, and asking the factory to name that pair back:
    ///
    ///        uniswap_v2   0x8bcEaA40…937f  getPair(a,a) ✓ (both orderings)
    ///        aeon_v2      0x38cA1727…d8f8  getPair(a,a) ✓
    ///        swaphood_v2  0xE7206Eca…8dD1  getPair(a,a) ✓
    ///        immutable_lp 0x135492B3…eD3F  getPair(a,a) ✓
    ///        rh_v2_d      0x002EC978…FB49  getPair(a,a) ✓
    ///        rh_v2_e      0x02a84c1b…749E  getPair(a,a) ✓
    ///        giga_v2      0x6Fdf38f9…0916  getPair(a,a) **REVERTS** — Solidly/Velodrome shape,
    ///                                      only `getPair(address,address,bool stable)` exists.
    ///                                      `UniV2GenericAdapter` probes that 3-arg shape with
    ///                                      `stable = false`, verified to name its volatile pairs
    ///                                      back (and to return address(0) for `stable = true`,
    ///                                      which is the desired refusal: a stable pair prices on
    ///                                      x³y+y³x=k and the adapter's 997/1000 math would
    ///                                      misprice it).
    ///
    ///      ⚠️ **DELIBERATELY OMITTED — rh_v2_c `0x5818fdDDdb96bCd50bee4253f11B324e7dEA961b`.**
    ///      It is in chain.rs but it is not a UniswapV2Factory: `getPair(address,address)` and
    ///      `allPairsLength()` BOTH revert, and its `PairCreated`-topic logs do not carry a pair
    ///      address in the canonical data slot (the decoded "pair" came back equal to token1).
    ///      No registry lane can authenticate its pools, so including it would add gas and grant
    ///      nothing. TODO(owner): its pools cannot execute through this adapter either way — decide
    ///      whether to drop it from `RH_V2_FACTORIES` (engine stops quoting unexecutable routes) or
    ///      to build the adapter its actual ABI needs, once someone identifies what it is.
    ///
    ///      ⚠️ TODO(owner), separate and non-blocking: `aeon_v2` pairs report `fee()` = 2500 (0.25%),
    ///      not the canonical 3000 that this adapter's hardcoded 997/1000 assumes, and two pairs
    ///      sampled from its `allPairs()` answer `factory()` with OTHER addresses (0xd8495e39…,
    ///      0x28a57a40…) — i.e. 0x38cA1727 behaves as a registry over pairs it did not itself create.
    ///      A 0.25% pair quoted at 0.3% UNDER-quotes, so the pair's k-check passes and the user is
    ///      merely paid slightly less than optimal; it is a pricing gap, not a safety one. Confirm
    ///      before leaning on this venue.
    function _rhV2Factories() internal pure returns (address[] memory f) {
        f = new address[](7);
        f[0] = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f; // uniswap_v2  ($62M/day on RH)
        f[1] = 0x38cA172774Fc3b6Fa0A39702249fd060B43cd8f8; // aeon_v2
        f[2] = 0xE7206Ecac3A51afe7e6179182ad4130A26068dD1; // swaphood_v2
        f[3] = 0x135492B3cCb2cb64749F91332F929F49a1DeeD3F; // immutable_lp
        f[4] = 0x002EC9782d70f4e79396c58964D4691cA648FB49; // rh_v2_d
        f[5] = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E; // rh_v2_e
        f[6] = 0x6Fdf38f92eAd1adFc04B73aaa947ab254f6c0916; // giga_v2 — 3-arg getPair(a,a,bool)
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    // Metric OMM
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev `MetricAdapter` is an `AllowlistAdapter`: Metric exposes no `getPool`-style view to
    ///      validate a caller-supplied pool against, so provenance is an IMMUTABLE allowlist fixed at
    ///      construction. All fourteen pools below were enumerated from `METRIC_FACTORY`'s
    ///      `PoolCreated` logs (topic0 `0xe1c304ac…93d4d`, from block 0 to head) on 2026-08-05, and
    ///      EACH was then confirmed by calling `getImmutables()` on the pool itself and checking that
    ///      the factory it reports is `METRIC_FACTORY`. The engine keeps all fourteen on this chain
    ///      (the recent-Swap liveness filter in `backfill_metric_pools` is Monad-only — an
    ///      oracle-anchored prop AMM keeps quoting while idle, and a genuinely dead feed mutes itself
    ///      by reverting `FeedStalled`), so the allowlist must mirror all fourteen or the adapter
    ///      would reject pools the router legitimately picks.
    ///
    ///      ⚠️ Adding a pool later = NEW adapter deployment + registry swap. That is the honest price
    ///      of refusing caller-supplied destinations; re-run the enumeration before any redeploy.
    ///
    ///      ⚠️ TODO(owner): chain.rs records a SECOND Metric factory (comment: "0x6229…EDe4, 4
    ///      pools") whose pools revert on this router and which chain.rs deliberately does not route.
    ///      Its full address is not recorded anywhere in this repo, so nothing here can reference it.
    ///      Left out on purpose — do not add pools from it without a router that accepts them.
    function _rhMetricPools() internal pure returns (address[] memory p) {
        p = new address[](14);
        p[0]  = 0x5f5A69Da5E22A4956a8316c62D578FC7e99cE967; // WETH9/USDG
        p[1]  = 0x027EeBBdF069F0fadA45C07a70d252C83520595c; // WETH9/USDG
        p[2]  = 0xf69F2921068Db8ADdC4B52DAe844413f7ee66b13; // 0x020bfc65…/USDG
        p[3]  = 0x4Af5B43f98bAc49d194F7570e24568368F6AE2DF; // 0x39dbed3a…/USDG
        p[4]  = 0xA992D98dF201F222F1A8AE5B024329F7F325cbD6; // WETH9/USDG
        p[5]  = 0x86585b67e28cacD7B1E9c4A324B54f5127B16773; // WETH9/USDG
        p[6]  = 0xE160fbF25b3CA404C3e54Cf6B7777BCd1e46238a; // WETH9/USDG
        p[7]  = 0x5bf0b7a40A4166E4549524198B512dB8D722D155; // 0x39dbed3a…/USDG
        p[8]  = 0xd289C9E70FFBD357d0A6b8d3Eaef304B72076555; // 0x020bfc65…/USDG
        p[9]  = 0x798705Cd91B62EF26502Bf6b42f7747Bbc9F710b; // 0x1b0e319c…/USDG
        p[10] = 0x98F4209E2b02D3540575530BCdC42472FE2F1ad0; // 0xd0601ce1…/USDG
        p[11] = 0x1bb1f2349fd11D67E977D9E49848043E407CDD10; // 0x4a0e65a3…/USDG
        p[12] = 0x94df2871CD9BbC863f28187Ab8aeeDeE83A77B7c; // WETH9/USDG
        p[13] = 0x813C6283BBCa33bb13c808f83a85D353ea26B074; // WETH9/USDG
    }
}
