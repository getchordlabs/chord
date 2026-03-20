// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NadFunDEXAdapter} from "../src/adapters/NadFunDEXAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployNadFunDEXOnlyScript is Script {
    address constant DEX_ROUTER = 0x0B79d71AE99528D1dB24A4148b5f4F865cc2b137;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NadFunDEXAdapter adapter = new NadFunDEXAdapter(DEX_ROUTER, WMON);
        console2.log("NadFunDEXAdapter v2:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
