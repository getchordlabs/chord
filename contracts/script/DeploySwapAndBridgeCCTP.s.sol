// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { SwapAndBridgeCCTP } from "../src/SwapAndBridgeCCTP.sol";

/// @notice Deploy SwapAndBridgeCCTP (Swap V2 P4, docs/swap-v2-crosschain.md §10) on a CCTP chain we
///         route on — Monad 143 or Arc 5042 (Base later). Same NullRouter proxy address on every chain
///         (aligned nonces); TokenMessengerV2 is Circle's deterministic deploy; USDC per chain.
/// @dev Usage (Monad needs --legacy, Arc does not; both want --gas-estimate-multiplier 200):
///        SAB_FEE_RECIPIENT=0x… SAB_FEE_BPS=10 forge script script/DeploySwapAndBridgeCCTP.s.sol \
///          --rpc-url "$MONAD_RPC_URL" --broadcast --legacy --gas-estimate-multiplier 200
///      After deploy: engine/API do NOT need to know it — the API's xswap planner gets a
///      `SWAP_AND_BRIDGE_<chain>` env pointing at it and swaps the two-step CCTP leg for one call
///      (txBuilder builds the router calldata with the contract as the caller). Ships dark until set.
contract DeploySwapAndBridgeCCTPScript is Script {
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant USDC_ARC = 0x3600000000000000000000000000000000000000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address feeRecipient = vm.envAddress("SAB_FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("SAB_FEE_BPS", uint256(10));
        address usdc = block.chainid == 143 ? USDC_MONAD : block.chainid == 5042 ? USDC_ARC : address(0);
        require(usdc != address(0), "unsupported chain: expected Monad 143 or Arc 5042");
        console2.log("Deployer:", vm.addr(pk));
        console2.log("chain:", block.chainid);
        console2.log("feeRecipient:", feeRecipient);
        console2.log("feeBps:", feeBps);

        vm.startBroadcast(pk);
        SwapAndBridgeCCTP sab = new SwapAndBridgeCCTP(NULL_ROUTER, usdc, TOKEN_MESSENGER_V2, feeRecipient, feeBps);
        vm.stopBroadcast();
        console2.log("SwapAndBridgeCCTP:", address(sab));
    }
}
