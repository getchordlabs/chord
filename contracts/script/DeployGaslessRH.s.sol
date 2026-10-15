// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GaslessEntry} from "../src/GaslessEntry.sol";

/// @notice Deploy GaslessEntry on Robinhood Chain (4663) and whitelist the relayer.
/// Same contract as the Monad deployment (0x4dACf25A…) — the EIP-712 domain binds
/// chainId + verifyingContract, so signatures can never replay across chains.
///
///   forge script script/DeployGaslessRH.s.sol --rpc-url $RH_RPC_URL --broadcast
contract DeployGaslessRH is Script {
    // NullRouter on 4663 — deployed at the SAME address as Monad (nonce-matched, I3).
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    // Wrapped native on 4663 = WETH9 (resolved on-chain from SwapRouter02.WETH9()).
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    // Relayer = the keeper/relayer service key (same signer as the Monad relayer).
    address constant RELAYER = 0x66449F79050828abb7A205434C0971dBA7a44C38;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a ROBINHOOD 4663 address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Monad 143 too. Without this line, pointing --rpc-url at Monad would
        // deploy an RH-configured contract and addAdapter it into the LIVE Monad registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 4663, "wrong chain: this script is Robinhood-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);
        GaslessEntry entry = new GaslessEntry(ROUTER, WETH9, deployer);
        entry.setRelayer(RELAYER, true);
        vm.stopBroadcast();

        console.log("GaslessEntry (4663):", address(entry));
        console.log("relayer whitelisted:", entry.isRelayer(RELAYER));
    }
}
