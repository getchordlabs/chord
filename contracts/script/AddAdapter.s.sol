// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Register a new adapter in AdapterRegistry
/// @dev Usage: ADAPTER=0x... forge script script/AddAdapter.s.sol --rpc-url https://rpc.monad.xyz --broadcast
contract AddAdapterScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address adapter = vm.envAddress("ADAPTER");

        vm.startBroadcast(deployerPrivateKey);

        // TODO: Call AdapterRegistry.addAdapter(adapter)

        console2.log("Adapter registered:", adapter);

        vm.stopBroadcast();
    }
}
