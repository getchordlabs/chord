// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GaslessEntryPermit2} from "../src/GaslessEntryPermit2.sol";

/// @notice Deploy GaslessEntryPermit2 (one-signature gasless swaps via Permit2).
/// @dev gasless-permit2-1sig-prompt.md. Ships DARK — no relayer whitelisted here; the relayer +
///      /v1/gasless wiring + FE stay behind env flags until owner review.
///      Monad: forge script … --rpc-url $MONAD_RPC_URL --broadcast --legacy
///      Robinhood Chain (Arbitrum-stack): same, WITHOUT --legacy.
contract DeployGaslessEntryPermit2Script is Script {
    // Canonical Permit2 — same address on every chain (verified on-chain: 9152 bytes on 143 + 4663).
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // NullRouter (UUPS) — same address on both chains.
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Wrapped native per chain: Monad WMON, Robinhood Chain WETH9.
        address wrapped = block.chainid == 4663
            ? 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
            : 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
        console2.log("Deployer:", deployer);
        console2.log("Chain:", block.chainid);

        vm.startBroadcast(pk);
        GaslessEntryPermit2 entry = new GaslessEntryPermit2(PERMIT2, ROUTER, wrapped, deployer);
        vm.stopBroadcast();

        console2.log("GaslessEntryPermit2:", address(entry));
        console2.log("  permit2:", address(entry.permit2()));
        console2.log("  router:", address(entry.router()));
    }
}
