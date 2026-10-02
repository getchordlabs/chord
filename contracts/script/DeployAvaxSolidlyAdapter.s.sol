// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordSolidlyAdapter} from "../src/chord/ChordSolidlyAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord Solidly adapter on Avalanche (43114) for Blackhole V1 pairs and register it.
/// @dev Factory 0xfe926062… = Blackhole V1 (Solidly "vAMM-/sAMM-" pairs, per-pair fee). Usage (from the Mac —
///      the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployAvaxSolidlyAdapter.s.sol --rpc-url "$AVAX_RPC" --broadcast
contract DeployAvaxSolidlyAdapterScript is Script {
    address constant BLACKHOLE_V1_FACTORY = 0xfE926062Fb99CA5653080d6C14fE945Ad68c265C;
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 43114, "wrong chain: Avalanche only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        address[] memory factories = new address[](1);
        factories[0] = BLACKHOLE_V1_FACTORY;

        vm.startBroadcast(pk);
        ChordSolidlyAdapter adapter = new ChordSolidlyAdapter(ROUTER, factories);
        console2.log("ChordSolidlyAdapter (Avalanche, Blackhole V1):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
