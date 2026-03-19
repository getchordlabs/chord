// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploy NullTerminal contracts to Monad mainnet
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url https://rpc.monad.xyz --broadcast
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // TODO: Deploy sequence:
        // 1. Deploy AdapterRegistry (UUPS proxy)
        // 2. Deploy FeeCollector (UUPS proxy)
        // 3. Deploy NullExecutor (UUPS proxy)
        // 4. Deploy NullRouter (UUPS proxy) — set executor, feeCollector, registry
        // 5. Deploy all adapters (immutable)
        // 6. Register adapters in AdapterRegistry

        console2.log("NullTerminal deployment complete");

        vm.stopBroadcast();
    }
}
