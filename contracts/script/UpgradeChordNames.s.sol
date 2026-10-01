// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {ChordAdapterRegistry} from "../src/chord/ChordAdapterRegistry.sol";
import {ChordFeeCollector} from "../src/chord/ChordFeeCollector.sol";
import {ChordRouter} from "../src/chord/ChordRouter.sol";

/// @title UpgradeChordNames
/// @notice Moves an aligned stack (same three proxies on every chain) onto the Chord-named implementations:
///         deploy ChordAdapterRegistry / ChordFeeCollector / ChordRouter, then `upgradeToAndCall(impl, "")` on each
///         proxy — 6 txs. The Chord contracts are the same code under a new name with no new state, so storage is
///         untouched; the script snapshots the state every swap depends on before and requires it unchanged after.
///         Written for Avalanche (deployed 2026-10-01 minutes before the rename); runs on any chain whose three
///         proxies the broadcasting key owns.
/// @dev  DEPLOYER_PRIVATE_KEY = the proxies' owner (0x0f11…4f79). Dry run: `--sig 'upgradeAs(address)' <owner>` on an
///       anvil fork (no key). CHORD_UPGRADE_REGISTRY / _COLLECTOR / _ROUTER (default true) pick the proxies: Monad / RH /
///       Arc moved the ROUTER only (owner 2026-10-02 — the one contract that carried the NullTerminal name; Monad's
///       AdapterRegistry impl 0x9121aff4 is an older 3,604 B build, not today's source, so it is never swapped for it).
contract UpgradeChordNames is Script {
    address internal constant REGISTRY_PROXY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address internal constant ROUTER_PROXY = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address internal constant COLLECTOR_PROXY = 0x6C66229675FD9cEDa9A9B2Ea2BD983B3d8255834;
    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Snapshot {
        address routerOwner;
        address wmon;
        address routerRegistry;
        address routerCollector;
        address[] adapters;
        address registryOwner;
        address collectorOwner;
        address treasury;
        uint16 feeBps;
        uint16 referralShareBps;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _upgrade(vm.addr(pk), pk);
    }

    function upgradeAs(address owner) external {
        _upgrade(owner, 0);
    }

    function _upgrade(address owner, uint256 pk) internal {
        bool doRegistry = vm.envOr("CHORD_UPGRADE_REGISTRY", true);
        bool doCollector = vm.envOr("CHORD_UPGRADE_COLLECTOR", true);
        bool doRouter = vm.envOr("CHORD_UPGRADE_ROUTER", true);
        require(doRegistry || doCollector || doRouter, "nothing selected");
        require(NullRouter(payable(ROUTER_PROXY)).owner() == owner, "not the router owner");
        require(AdapterRegistry(REGISTRY_PROXY).owner() == owner, "not the registry owner");
        require(FeeCollector(COLLECTOR_PROXY).owner() == owner, "not the collector owner");
        Snapshot memory before = _snapshot();
        address registryBefore = _impl(REGISTRY_PROXY);
        address collectorBefore = _impl(COLLECTOR_PROXY);
        address routerBefore = _impl(ROUTER_PROXY);

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast(owner);
        address registryImpl = doRegistry ? address(new ChordAdapterRegistry()) : registryBefore;
        address collectorImpl = doCollector ? address(new ChordFeeCollector()) : collectorBefore;
        address routerImpl = doRouter ? address(new ChordRouter()) : routerBefore;
        if (doRegistry) UUPSUpgradeable(REGISTRY_PROXY).upgradeToAndCall(registryImpl, "");
        if (doCollector) UUPSUpgradeable(COLLECTOR_PROXY).upgradeToAndCall(collectorImpl, "");
        if (doRouter) UUPSUpgradeable(ROUTER_PROXY).upgradeToAndCall(routerImpl, "");
        vm.stopBroadcast();

        require(_impl(REGISTRY_PROXY) == registryImpl, "registry impl not where it should be");
        require(_impl(COLLECTOR_PROXY) == collectorImpl, "collector impl not where it should be");
        require(_impl(ROUTER_PROXY) == routerImpl, "router impl not where it should be");
        _requireSame(before, _snapshot());

        console2.log(string.concat("=== Chord names on chain ", vm.toString(block.chainid), " ==="));
        console2.log(doRegistry ? "ChordAdapterRegistry impl:" : "AdapterRegistry impl (kept):", registryImpl);
        console2.log(doCollector ? "ChordFeeCollector impl:   " : "FeeCollector impl (kept):  ", collectorImpl);
        console2.log(doRouter ? "ChordRouter impl:         " : "router impl (kept):        ", routerImpl);
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        NullRouter r = NullRouter(payable(ROUTER_PROXY));
        FeeCollector f = FeeCollector(COLLECTOR_PROXY);
        s.routerOwner = r.owner();
        s.wmon = r.wmon();
        s.routerRegistry = address(r.registry());
        s.routerCollector = address(r.feeCollector());
        s.adapters = AdapterRegistry(REGISTRY_PROXY).getApprovedAdapters();
        s.registryOwner = AdapterRegistry(REGISTRY_PROXY).owner();
        s.collectorOwner = f.owner();
        s.treasury = f.treasury();
        s.feeBps = f.feeBps();
        s.referralShareBps = f.referralShareBps();
    }

    function _requireSame(Snapshot memory a, Snapshot memory b) internal pure {
        require(a.routerOwner == b.routerOwner && a.registryOwner == b.registryOwner && a.collectorOwner == b.collectorOwner, "owner changed");
        require(a.wmon == b.wmon && a.routerRegistry == b.routerRegistry && a.routerCollector == b.routerCollector, "router wiring changed");
        require(a.treasury == b.treasury && a.feeBps == b.feeBps && a.referralShareBps == b.referralShareBps, "fee state changed");
        require(a.adapters.length == b.adapters.length, "adapter set changed");
        for (uint256 i = 0; i < a.adapters.length; i++) require(a.adapters[i] == b.adapters[i], "adapter set changed");
    }
}
