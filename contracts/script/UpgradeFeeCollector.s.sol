// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @title UpgradeFeeCollector
/// @notice Owner-run UUPS upgrade that adds Jupiter-style tiered per-token fees to a live FeeCollector.
/// @dev New storage is APPENDED (preserves layout), so this upgrade alone changes nothing — every token
///      keeps resolving to the global 5bps default until per-token overrides are set (SetFeeTiers.s.sol).
///      The broadcaster MUST be the FeeCollector owner.
///
///      FEE_COLLECTOR=0x6c66229675fd9ceda9a9b2ea2bd983b3d8255834 \
///      forge script script/UpgradeFeeCollector.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
contract UpgradeFeeCollector is Script {
    function run() external {
        address proxy = vm.envAddress("FEE_COLLECTOR");

        vm.startBroadcast();
        FeeCollector newImpl = new FeeCollector();
        FeeCollector(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console2.log("FeeCollector proxy   :", proxy);
        console2.log("new implementation   :", address(newImpl));
        console2.log("default feeBps (unchanged):", FeeCollector(proxy).feeBps());
    }
}
