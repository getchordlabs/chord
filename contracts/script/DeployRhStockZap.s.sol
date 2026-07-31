// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RhStockZap} from "../src/RhStockZap.sol";

/// @notice Deploy the RhStockZap destination-execution proxy on Robinhood Chain (4663).
/// @dev one-click-stock-prompt.md P1. Arbitrum-stack: NO --legacy, EIP-1559 fine.
///      Usage:
///        forge script script/DeployRhStockZap.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///          --broadcast --gas-estimate-multiplier 200
///      Verify (Blockscout, NOT Sourcify):
///        forge verify-contract <addr> RhStockZap --verifier blockscout \
///          --verifier-url https://robinhoodchain.blockscout.com/api \
///          --constructor-args $(cast abi-encode "constructor(address,address)" \
///            0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xCaf681a66D020601342297493863E78C959E5cb2)
contract DeployRhStockZapScript is Script {
    // USDG on 4663 (6 decimals, Paxos) — the bridge anchor the zap always spends.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // Uniswap V3 SwapRouter02 on 4663 — WETH9()/factory() on-chain-verified to the RH UniV3 deploy.
    address constant SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain 4663");

        vm.startBroadcast(deployerPrivateKey);
        RhStockZap zap = new RhStockZap(USDG, SWAP_ROUTER02);
        vm.stopBroadcast();

        console2.log("RhStockZap (4663):", address(zap));
        console2.log("USDG:", address(zap.USDG()));
        console2.log("ROUTER:", address(zap.ROUTER()));
    }
}
