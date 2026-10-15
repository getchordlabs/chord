// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullOneClickExecutor} from "../src/NullOneClickExecutor.sol";

/// @notice Deploy NullOneClickExecutor (allowance-based 1-click, DARK). Monad needs --legacy.
/// @dev docs/oneclick-allowance-prompt.md. keeper is IMMUTABLE — pass the relayer via env
///      ONECLICK_KEEPER (defaults to the deployer for a dry run).
///        forge script script/DeployNullOneClickExecutor.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
contract DeployNullOneClickExecutorScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address keeper = vm.envOr("ONECLICK_KEEPER", deployer);
        require(block.chainid == 143, "expected Monad 143");
        console2.log("Deployer:", deployer, "| keeper:", keeper);

        vm.startBroadcast(pk);
        NullOneClickExecutor exec = new NullOneClickExecutor(ROUTER, keeper);
        vm.stopBroadcast();

        console2.log("NullOneClickExecutor:", address(exec));
    }
}
