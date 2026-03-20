// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CloberAdapter} from "../src/adapters/CloberAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployCloberAdapterScript is Script {
    address constant CLOBER_CONTROLLER = 0x19b68a2b909D96c05B623050C276FBD457De8e83;
    address constant BOOK_MANAGER = 0x6657d192273731C3cAc646cc82D5F28D0CBE8CCC;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        CloberAdapter adapter = new CloberAdapter(CLOBER_CONTROLLER, BOOK_MANAGER);
        console2.log("CloberAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
