// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullRouter} from "../src/NullRouter.sol";

contract UpgradeRouterV3Script is Script {
    address constant ROUTER_PROXY = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NullRouter newImpl = new NullRouter();
        console2.log("New impl:", address(newImpl));

        NullRouter(payable(ROUTER_PROXY)).upgradeToAndCall(address(newImpl), "");
        console2.log("Upgraded");

        NullRouter(payable(ROUTER_PROXY)).setPermit2(PERMIT2);
        console2.log("Permit2 set");

        vm.stopBroadcast();
    }
}
