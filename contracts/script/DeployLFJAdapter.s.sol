// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LFJAdapter} from "../src/adapters/LFJAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployLFJAdapterScript is Script {
    address constant LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        LFJAdapter adapter = new LFJAdapter(LB_ROUTER);
        console2.log("LFJAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
