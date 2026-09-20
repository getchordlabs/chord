// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { RhTokenZap } from "../src/RhTokenZap.sol";

/// @notice Deploy the generic destination-execution zap on Robinhood Chain (4663) — Swap V2 P4
///         (docs/swap-v2-crosschain.md §10): any token via NullRouter, replaces RhStockZap's
///         single-pool stock path for the Relay `txs` corridor.
/// @dev Arbitrum-stack: NO --legacy.
///        forge script script/DeployRhTokenZap.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///          --broadcast --gas-estimate-multiplier 200
///      Verify on Blockscout like DeployRhStockZap. Then set RH_TOKEN_ZAP_ADDRESS in the VPS .env —
///      the API only uses it once that env is present (ships dark).
contract DeployRhTokenZapScript is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NULL_ROUTER_RH = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain 4663");
        console2.log("Deployer:", vm.addr(pk));
        vm.startBroadcast(pk);
        RhTokenZap zap = new RhTokenZap(USDG, NULL_ROUTER_RH);
        vm.stopBroadcast();
        console2.log("RhTokenZap:", address(zap));
    }
}
