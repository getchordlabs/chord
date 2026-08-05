// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NadFunBCAdapter} from "../src/adapters/NadFunBCAdapter.sol";
import {NadFunDEXAdapter} from "../src/adapters/NadFunDEXAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployNadFunAdaptersScript is Script {
    address constant BC_ROUTER = 0x6F6B8F1a20703309951a5127c45B49b1CD981A22;
    address constant DEX_ROUTER = 0x0B79d71AE99528D1dB24A4148b5f4F865cc2b137;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NadFunBCAdapter bcAdapter = new NadFunBCAdapter(NULL_ROUTER, BC_ROUTER, WMON);
        console2.log("NadFunBCAdapter:", address(bcAdapter));

        NadFunDEXAdapter dexAdapter = new NadFunDEXAdapter(NULL_ROUTER, DEX_ROUTER, WMON);
        console2.log("NadFunDEXAdapter:", address(dexAdapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(bcAdapter));
        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(dexAdapter));
        console2.log("Both registered");

        vm.stopBroadcast();
    }
}
