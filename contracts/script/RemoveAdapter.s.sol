// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice De-register adapters from AdapterRegistry (batch) — the missing half of AddAdapter.
/// @dev Audit 2026-08-05 (M2): 18 of 37 approved adapters are stale — known-buggy versions
///      (pre-native-out V4, TwoCrypto CurveAdapter, router-based nad.fun), `CloberAdapter` which
///      still holds 1 WMON, and ~8 nobody can identify. The engine picking routes is NOT the gate:
///      `isApproved` is, and anyone can hand-craft a RouteStep naming any approved adapter. There
///      was no removal tooling at all, so the sweep had nothing to run.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY  registry owner
///   ADAPTERS              comma-separated adapter addresses to remove (or ADAPTER for one)
///   REGISTRY              optional override of the pinned Monad AdapterRegistry proxy
///
/// Run:  ADAPTERS=0xaaa,0xbbb forge script script/RemoveAdapter.s.sol \
///         --rpc-url $MONAD_RPC_URL --broadcast --legacy
///
/// SAFETY: removing an adapter that IS still routed breaks every quote using it (the router then
/// reverts `UnapprovedAdapter`). Diff the list against the engine's live adapter set first, and
/// drain any balance the adapter holds — removal does not move funds.
contract RemoveAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        AdapterRegistry registry = AdapterRegistry(vm.envOr("REGISTRY", ADAPTER_REGISTRY));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _removeAll(registry, _targets());
        vm.stopBroadcast();
    }

    /// @dev Kept out of `run` so via_ir stays off the stack-too-deep edge.
    function _targets() internal view returns (address[] memory adapters) {
        adapters = vm.envOr("ADAPTERS", ",", new address[](0));
        if (adapters.length == 0) {
            adapters = new address[](1);
            adapters[0] = vm.envAddress("ADAPTER");
        }
    }

    function _removeAll(AdapterRegistry registry, address[] memory adapters) internal {
        console2.log("AdapterRegistry:", address(registry));
        console2.log("approved before:", registry.getApprovedAdapters().length);
        for (uint256 i = 0; i < adapters.length; i++) {
            address adapter = adapters[i];
            if (!registry.isApproved(adapter)) {
                console2.log("not approved, skipping:", adapter);
                continue;
            }
            registry.removeAdapter(adapter);
            require(!registry.isApproved(adapter), "REMOVE_FAILED");
            console2.log("adapter removed:", adapter);
        }
        console2.log("approved after:", registry.getApprovedAdapters().length);
    }
}
