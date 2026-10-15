// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordSolidlyAdapter} from "../src/chord/ChordSolidlyAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord Solidly adapter on Base (8453) for Aerodrome V2 pools and register it.
/// @dev Factory 0x420DD381… = Aerodrome V2 PoolFactory (`getPool(a, b, stable)`; no `getPair`). Usage (from the Mac):
///        forge script script/DeployBaseSolidlyAdapter.s.sol --rpc-url "$BASE_RPC" --broadcast
contract DeployBaseSolidlyAdapterScript is Script {
    address constant AERODROME_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 8453, "wrong chain: Base only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        address[] memory factories = new address[](1);
        factories[0] = AERODROME_V2_FACTORY;

        vm.startBroadcast(pk);
        ChordSolidlyAdapter adapter = new ChordSolidlyAdapter(ROUTER, factories);
        console2.log("ChordSolidlyAdapter (Base, Aerodrome V2):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
