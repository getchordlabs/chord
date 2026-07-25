// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MentoAdapter} from "../src/adapters/MentoAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployMentoAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev Mento protocol Router on Monad (docs.mento.org, defaultFactory verified on-chain).
    address constant MENTO_ROUTER = 0x4861840C2EfB2b98312B0aE34d86fD73E8f9B6f6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MentoAdapter adapter = new MentoAdapter(MENTO_ROUTER);
        console2.log("MentoAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
