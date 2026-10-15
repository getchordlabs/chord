// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {NullRouter} from "../../src/NullRouter.sol";
import {ChordAdapterRegistry} from "../../src/chord/ChordAdapterRegistry.sol";
import {ChordFeeCollector} from "../../src/chord/ChordFeeCollector.sol";
import {ChordRouter} from "../../src/chord/ChordRouter.sol";

/// @dev The one property every H1-hardened adapter shares (BaseAdapter): the router it pins.
interface IPinnedAdapter {
    function NULL_ROUTER() external view returns (address);
}

/// @title AlignedStackDeploy
/// @notice Shared body of `DeployBase` / `DeployAvalanche` / `DeployBnb` / `DeployArbitrum` (docs/multichain-plan.md §3 M3):
///         the NullTerminal core stack — AdapterRegistry + NullRouter + FeeCollector (UUPS proxies) — at
///         the SAME proxy addresses as Monad / Robinhood Chain / Arc, plus the chain's adapter set.
/// @dev THE TEMPLATE IS `script/DeployArc.s.sol` (deployed 2026-09-16). What is added here is only what
///      the Arc run taught: the nonce map is enforced instead of printed, and every aligned address is
///      re-derived BEFORE the first transaction and read back AFTER the last one.
///
///      NONCE MAP — identical on every chain (read on-chain for Monad/RH/Arc 2026-09-16, re-derived with
///      `cast compute-address 0x0f11…4f79 --nonce N` 2026-09-30):
///        0 AdapterRegistry impl  (0x9121AFF4…)
///        1 AdapterRegistry PROXY (0x6Cf25d2a…)  ← aligned
///        2 FeeCollector impl     (0x4bD6cc6b…)  — the "any contract" slot
///        3 NullRouter impl       (0x1cd8CeED…)
///        4 NullRouter PROXY      (0x1B1Fee89…)  ← aligned
///        5 V3-family adapter     (0xd55fe37e…)  — the second "any contract" slot (needs the router)
///        6 FeeCollector PROXY    (0x6C662296…)  ← aligned
///        7 router.setFeeCollector · 8 registry.addAdapter(v3) · 9+ remaining adapters + addAdapter
///        last: feeCollector.setTokenFeeBpsBatch (zero-fee majors — OWNER GATE)
///      Anything that changes this order before nonce 6 — a failed tx, a stray `new`, a "dry" run that
///      still broadcasts — moves every later address. There is no way back on the same key, which is
///      why `_preflight` refuses to start unless the deployer's nonce is exactly EXPECTED_START_NONCE.
///      (The deployer EOA 0x0f11…4f79 read nonce 0 on 8453 / 43114 / 56 on 2026-09-30, and on 42161 on 2026-10-14.)
///
///      Adapters are H1-hardened (`BaseAdapter`): each pins the NullRouter PROXY as an immutable and
///      reverts `NotRouter` (0x91655201) for every other caller.
///
///      Names (owner 2026-10-01): the implementations deploy as ChordAdapterRegistry / ChordFeeCollector /
///      ChordRouter (src/chord — the same code under the Chord name, no new state) and the per-chain scripts use the
///      Chord* adapters. CREATE addresses depend on deployer + nonce only, so the nonce map above is unchanged.
///      Avalanche (2026-10-01) was deployed just before the rename and moved to these impls by
///      script/UpgradeChordNames.s.sol.
abstract contract AlignedStackDeploy is Script {
    // ── aligned core (same on Monad 143 / RH 4663 / Arc 5042) ───────────────────────────────────
    address internal constant EXPECTED_DEPLOYER = 0x0f1171209dAD379AF0E486f2c77D275D6E0a4f79;
    uint64 internal constant EXPECTED_START_NONCE = 0;
    address internal constant REGISTRY_PROXY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address internal constant ROUTER_PROXY = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address internal constant COLLECTOR_PROXY = 0x6C66229675FD9cEDa9A9B2Ea2BD983B3d8255834;

    // ── fee model — OWNER GATE ───────────────────────────────────────────────────────────────────
    // Same numbers as DeployArc (default 25 bps, 50 % referral split). Monad runs a 50 bps default
    // (new-token tier) because the feechurn keeper downgrades aged tokens there; no keeper exists on
    // these chains yet (docs/fee-tiers.md). The owner decides; `setFeeBps` / `setTokenFeeBpsBatch`
    // change it later without a redeploy. Cap is 100 bps in BOTH the collector and the router.
    uint16 internal constant DEFAULT_FEE_BPS = 25; // OWNER GATE
    uint16 internal constant REFERRAL_SHARE_BPS = 5000; // OWNER GATE

    /// @notice Global default the collector is INITIALISED with. Base / BNB / Avalanche broadcast 25 (2026-10-01) and
    ///         were moved to 5 by `setFeeBps(5)` on 2026-10-02 (owner: one 5 bps default on every chain,
    ///         docs/fee-tiers.md); those scripts keep 25 so they still describe what was broadcast. A chain deployed
    ///         after that call overrides this to start at 5 (DeployArbitrum) — one transaction fewer, no 25 window.
    function defaultFeeBps() public pure virtual returns (uint16) {
        return DEFAULT_FEE_BPS;
    }

    struct Stack {
        AdapterRegistry registry;
        address registryImpl;
        NullRouter router;
        address routerImpl;
        FeeCollector feeCollector;
        address feeCollectorImpl;
        address v3Adapter;
        address[] adapters; // every adapter this run approved, v3Adapter first
        string[] names;
    }

    // ── per-chain hooks ──────────────────────────────────────────────────────────────────────────
    function chainIdExpected() public pure virtual returns (uint256);
    function chainName() public pure virtual returns (string memory);
    /// @dev NullRouter `wmon` slot: the chain's REAL wrapped native (WETH / WAVAX / WBNB) — native-in
    ///      wraps via deposit(), native-out unwraps via withdraw(). Unlike Arc there is no view token.
    function wrappedNative() public pure virtual returns (address);
    /// @dev Deployed at NONCE 5 — must be exactly one CREATE and nothing else.
    function _deployV3Adapter(address router) internal virtual returns (address);
    /// @dev Deployed after nonce 8; the base approves each one in the registry afterwards.
    function _deployOtherAdapters(address router)
        internal
        virtual
        returns (address[] memory adapters, string[] memory names);
    /// @dev OWNER GATE — tokens whose OUTPUT is charged 0 bps (stables + majors, docs/fee-tiers.md).
    function zeroFeeTokens() public pure virtual returns (address[] memory);
    /// @dev Chain-specific code-existence checks (factories, PoolManager, LB router …).
    function _preflightChain() internal view virtual;

    // ── entrypoints ──────────────────────────────────────────────────────────────────────────────

    /// @notice Broadcast entry (`forge script … --broadcast`). Env: DEPLOYER_PRIVATE_KEY (OWNER GATE),
    ///         TREASURY_ADDRESS (optional, defaults to the deployer — Monad's treasury IS the deployer).
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        _preflight(deployer);
        vm.startBroadcast(pk);
        Stack memory s = _deploy(deployer, treasury);
        vm.stopBroadcast();
        _postflight(s, deployer, treasury);
        _log(s, treasury);
    }

    /// @notice Fork-test entry — the SAME body broadcast as an unlocked address (no key). Only
    ///         meaningful under `forge test --fork-url …`; a script contract is never deployed on chain.
    function deployAs(address deployer, address treasury) external returns (Stack memory s) {
        _preflight(deployer);
        vm.startBroadcast(deployer);
        s = _deploy(deployer, treasury);
        vm.stopBroadcast();
        _postflight(s, deployer, treasury);
        _log(s, treasury);
    }

    // ── body ─────────────────────────────────────────────────────────────────────────────────────

    function _deploy(address deployer, address treasury) internal returns (Stack memory s) {
        // nonce 0, 1 — AdapterRegistry
        AdapterRegistry registryImpl = new ChordAdapterRegistry();
        ERC1967Proxy registryProxy =
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(AdapterRegistry.initialize, (deployer)));
        s.registry = AdapterRegistry(address(registryProxy));
        s.registryImpl = address(registryImpl);

        // nonce 2 — FeeCollector impl (constructor-only, fills the first "any contract" slot)
        FeeCollector feeCollectorImpl = new ChordFeeCollector();
        s.feeCollectorImpl = address(feeCollectorImpl);

        // nonce 3, 4 — NullRouter. Placeholder collector (wired at nonce 7). `executor` is a
        // deprecated storage-layout slot: address(0), never re-add (packages/contracts/CLAUDE.md).
        NullRouter routerImpl = new ChordRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                NullRouter.initialize, (deployer, wrappedNative(), address(0), address(1), address(s.registry))
            )
        );
        s.router = NullRouter(payable(address(routerProxy)));
        s.routerImpl = address(routerImpl);

        // nonce 5 — V3-family adapter (second "any contract" slot; needs the router address)
        s.v3Adapter = _deployV3Adapter(address(s.router));

        // nonce 6 — FeeCollector proxy
        ERC1967Proxy feeCollectorProxy = new ERC1967Proxy(
            address(feeCollectorImpl),
            abi.encodeCall(
                FeeCollector.initialize, (deployer, treasury, address(s.router), defaultFeeBps(), REFERRAL_SHARE_BPS)
            )
        );
        s.feeCollector = FeeCollector(address(feeCollectorProxy));

        // nonce 7, 8 — wire the collector, approve the V3 adapter
        s.router.setFeeCollector(address(s.feeCollector));
        s.registry.addAdapter(s.v3Adapter);

        // nonce 9+ — the rest of the adapter set, each approved
        (address[] memory others, string[] memory otherNames) = _deployOtherAdapters(address(s.router));
        require(others.length == otherNames.length, "adapter/name length mismatch");
        for (uint256 i = 0; i < others.length; i++) {
            s.registry.addAdapter(others[i]);
        }

        s.adapters = new address[](others.length + 1);
        s.names = new string[](others.length + 1);
        s.adapters[0] = s.v3Adapter;
        s.names[0] = "ChordV3Adapter";
        for (uint256 i = 0; i < others.length; i++) {
            s.adapters[i + 1] = others[i];
            s.names[i + 1] = otherNames[i];
        }

        // last — zero-fee majors/stables (OWNER GATE: list lives in the per-chain script)
        address[] memory zero = zeroFeeTokens();
        if (zero.length > 0) {
            s.feeCollector.setTokenFeeBpsBatch(zero, new uint16[](zero.length));
        }
    }

    // ── checks ───────────────────────────────────────────────────────────────────────────────────

    /// @dev Everything here runs BEFORE the first transaction; a failure costs nothing.
    function _preflight(address deployer) internal view {
        require(block.chainid == chainIdExpected(), string.concat("wrong chain: expected ", chainName()));
        // Alignment is a property of (deployer, nonce) only — check both, then re-derive the three
        // proxy addresses so a wrong key or a wrong map is caught here and not after nonce 6.
        require(deployer == EXPECTED_DEPLOYER, "deployer is not 0x0f11...4f79 - proxies would not align");
        require(
            vm.getNonce(deployer) == EXPECTED_START_NONCE,
            "deployer nonce != EXPECTED_START_NONCE - aligned addresses are unreachable, STOP (runbook s.1)"
        );
        require(vm.computeCreateAddress(deployer, 1) == REGISTRY_PROXY, "nonce map: registry proxy");
        require(vm.computeCreateAddress(deployer, 4) == ROUTER_PROXY, "nonce map: router proxy");
        require(vm.computeCreateAddress(deployer, 6) == COLLECTOR_PROXY, "nonce map: collector proxy");
        require(
            REGISTRY_PROXY.code.length == 0 && ROUTER_PROXY.code.length == 0 && COLLECTOR_PROXY.code.length == 0,
            "a core proxy already has code on this chain"
        );
        require(wrappedNative().code.length > 0, "wrapped native has no code");
        _preflightChain();
    }

    /// @dev Read-back after the last transaction: aligned addresses, wiring, pins, approvals, fees.
    function _postflight(Stack memory s, address deployer, address treasury) internal view {
        require(address(s.registry) == REGISTRY_PROXY, "registry proxy NOT aligned");
        require(address(s.router) == ROUTER_PROXY, "router proxy NOT aligned");
        require(address(s.feeCollector) == COLLECTOR_PROXY, "collector proxy NOT aligned");

        require(address(s.router.registry()) == address(s.registry), "router.registry");
        require(address(s.router.feeCollector()) == address(s.feeCollector), "router.feeCollector");
        require(s.router.wmon() == wrappedNative(), "router.wmon");
        require(s.router.owner() == deployer, "router.owner");
        require(s.registry.owner() == deployer, "registry.owner");
        require(s.feeCollector.owner() == deployer, "collector.owner");
        require(s.feeCollector.router() == address(s.router), "collector.router");
        require(s.feeCollector.treasury() == treasury, "collector.treasury");
        require(s.feeCollector.feeBps() == defaultFeeBps(), "collector.feeBps");
        require(s.feeCollector.referralShareBps() == REFERRAL_SHARE_BPS, "collector.referralShareBps");

        for (uint256 i = 0; i < s.adapters.length; i++) {
            require(s.registry.isApproved(s.adapters[i]), "adapter not approved");
            require(IPinnedAdapter(s.adapters[i]).NULL_ROUTER() == address(s.router), "adapter NULL_ROUTER pin");
        }
        require(s.registry.adapterCount() == s.adapters.length, "registry holds extra adapters");

        address[] memory zero = zeroFeeTokens();
        for (uint256 i = 0; i < zero.length; i++) {
            require(s.feeCollector.feeBpsFor(zero[i]) == 0, "zero-fee token not zero");
        }
    }

    function _log(Stack memory s, address treasury) internal view {
        console2.log(string.concat("=== Chord on ", chainName(), " ==="));
        console2.log("chainId:              ", block.chainid);
        console2.log("ChordAdapterRegistry proxy:", address(s.registry));
        console2.log("ChordAdapterRegistry impl: ", s.registryImpl);
        console2.log("ChordRouter proxy:         ", address(s.router));
        console2.log("ChordRouter impl:          ", s.routerImpl);
        console2.log("ChordFeeCollector proxy:   ", address(s.feeCollector));
        console2.log("ChordFeeCollector impl:    ", s.feeCollectorImpl);
        console2.log("Treasury:             ", treasury);
        for (uint256 i = 0; i < s.adapters.length; i++) {
            console2.log(string.concat(s.names[i], ":"), s.adapters[i]);
        }
    }
}
