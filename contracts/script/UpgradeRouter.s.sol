// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullRouter} from "../src/NullRouter.sol";

/// @notice Upgrade NullRouter implementation (UUPS)
/// @dev Usage: forge script script/UpgradeRouter.s.sol --rpc-url <RPC> --broadcast
contract UpgradeRouterScript is Script {
    address constant ROUTER_PROXY = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        NullRouter newImpl = new NullRouter();
        console2.log("New NullRouter impl:", address(newImpl));

        // Upgrade proxy to new implementation
        NullRouter(payable(ROUTER_PROXY)).upgradeToAndCall(address(newImpl), "");
        console2.log("Router proxy upgraded");

        vm.stopBroadcast();
    }
}
