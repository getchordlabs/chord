// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Register one or more adapters in AdapterRegistry.
/// @dev Audit 2026-08-05 (M2): this script used to log "Adapter registered" from a `// TODO` stub
///      that never called `addAdapter` — an operator following the runbook would believe an adapter
///      was whitelisted when it was not. It now calls the registry for real and reads `isApproved`
///      back inside the broadcast, so a silent failure is impossible.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY  registry owner
///   ADAPTERS              comma-separated adapter addresses (preferred), OR
///   ADAPTER               a single adapter address (back-compat with the old runbook)
///   REGISTRY              optional override of the pinned Monad AdapterRegistry proxy
///
/// Run:  ADAPTERS=0xaaa,0xbbb forge script script/AddAdapter.s.sol \
///         --rpc-url $MONAD_RPC_URL --broadcast --legacy
/// (forge broadcast is flaky on Monad — fall back to
///  `cast send $REGISTRY "addAdapter(address)" $ADAPTER --legacy`.)
contract AddAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        AdapterRegistry registry = AdapterRegistry(vm.envOr("REGISTRY", ADAPTER_REGISTRY));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _addAll(registry, _targets());
        vm.stopBroadcast();
    }

    /// @dev ADAPTERS (list) wins; ADAPTER (single) is the back-compat fallback.
    ///      Kept out of `run` so via_ir stays off the stack-too-deep edge.
    function _targets() internal view returns (address[] memory adapters) {
        adapters = vm.envOr("ADAPTERS", ",", new address[](0));
        if (adapters.length == 0) {
            adapters = new address[](1);
            adapters[0] = vm.envAddress("ADAPTER");
        }
    }

    function _addAll(AdapterRegistry registry, address[] memory adapters) internal {
        console2.log("AdapterRegistry:", address(registry));
        for (uint256 i = 0; i < adapters.length; i++) {
            address adapter = adapters[i];
            if (registry.isApproved(adapter)) {
                console2.log("already approved, skipping:", adapter);
                continue;
            }
            registry.addAdapter(adapter);
            // Read back: the whole point of the M2 fix is that this script never reports a success
            // it did not achieve.
            require(registry.isApproved(adapter), "ADD_FAILED");
            console2.log("adapter registered:", adapter);
        }
        console2.log("approved adapter count:", registry.getApprovedAdapters().length);
    }
}
