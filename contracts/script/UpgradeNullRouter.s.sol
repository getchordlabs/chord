// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullRouter} from "../src/NullRouter.sol";

/// @title UpgradeNullRouter
/// @notice Owner-run UUPS upgrade so the router reads the tiered `feeCollector.feeBpsFor(tokenOut)`.
/// @dev ⚠️ This deploys a FRESH NullRouter implementation from the CURRENT source tree — it ships
///      EVERY undeployed change in NullRouter.sol, not only the one-line fee read (e.g. the dff96f8
///      fund-safety fixes if those were never broadcast). Review the full deployed-vs-HEAD delta before
///      broadcasting. The broadcaster MUST be the NullRouter owner.
///
///      NULL_ROUTER=0x1b1fee89a381e595fe6536b99ba91f3e16e9601a \
///      forge script script/UpgradeNullRouter.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
contract UpgradeNullRouter is Script {
    function run() external {
        address proxy = vm.envAddress("NULL_ROUTER");

        vm.startBroadcast();
        NullRouter newImpl = new NullRouter();
        NullRouter(payable(proxy)).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console2.log("NullRouter proxy   :", proxy);
        console2.log("new implementation :", address(newImpl));
    }
}
