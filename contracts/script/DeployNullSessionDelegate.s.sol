// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullSessionDelegate} from "../src/NullSessionDelegate.sol";

/// @notice Deploy NullSessionDelegate (EIP-7702 session trading, DARK). Monad needs --legacy.
/// @dev session-trading-v2-prompt.md. Relayer is IMMUTABLE — pass the co-signer via env
///      SESSION_RELAYER (defaults to the deployer for validation).
///        forge script script/DeployNullSessionDelegate.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
contract DeployNullSessionDelegateScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address relayer = vm.envOr("SESSION_RELAYER", deployer);
        require(block.chainid == 143, "expected Monad 143");
        console2.log("Deployer:", deployer, "| relayer(co-signer):", relayer);

        vm.startBroadcast(pk);
        NullSessionDelegate d = new NullSessionDelegate(ROUTER, relayer, WMON);
        vm.stopBroadcast();

        console2.log("NullSessionDelegate:", address(d));
    }
}
