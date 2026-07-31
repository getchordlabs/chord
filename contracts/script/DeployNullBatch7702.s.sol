// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullBatch7702} from "../src/NullBatch7702.sol";

/// @notice Deploy the NullBatch7702 EIP-7702 delegate on Monad (143).
/// @dev monad-7702-oneclick-prompt.md P1. Monad needs --legacy.
///      Usage:
///        forge script script/DeployNullBatch7702.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
///      Verify (Sourcify / monadscan): standard forge verify-contract.
contract DeployNullBatch7702Script is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        require(block.chainid == 143, "wrong chain: expected Monad 143");

        vm.startBroadcast(deployerPrivateKey);
        NullBatch7702 batch = new NullBatch7702();
        vm.stopBroadcast();

        console2.log("NullBatch7702 (143):", address(batch));
    }
}
