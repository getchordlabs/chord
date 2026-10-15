// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @title SetFeeTiers
/// @notice Owner-run: apply per-token fee overrides in one batched tx (the tiered-fee "push" step).
/// @dev Fill `tokens`/`bps` from the reviewed diff at GET /v1/admin/fee-tiers BEFORE broadcasting.
///      Every value is hard-capped on-chain at 100 bps (1%). Empty arrays = no-op (safe dry run).
///
///      ⚠️ ORDERING: do NOT run this until the API's minOut is tier-aware (it must reserve slippage for
///      the ACTUAL on-chain fee, else a tighter-fee assumption trips InsufficientOutput). See
///      docs/fee-tiers.md.
///
///      FEE_COLLECTOR=0x6c66229675fd9ceda9a9b2ea2bd983b3d8255834 \
///      forge script script/SetFeeTiers.s.sol --rpc-url $MONAD_RPC_URL --broadcast --legacy
contract SetFeeTiers is Script {
    function run() external {
        address fc = vm.envAddress("FEE_COLLECTOR");

        // ── EDIT ME: the reviewed (token → bps) overrides. Example shape (commented out): ──
        // tokens[0] = 0xMemeToken; bps[0] = 30;  // meme tier
        // tokens[1] = 0xFreshToken; bps[1] = 50; // new (<24h) tier
        address[] memory tokens = new address[](0);
        uint16[] memory bps = new uint16[](0);

        require(tokens.length == bps.length, "LENGTH_MISMATCH");
        if (tokens.length == 0) {
            console2.log("No tiers to set - populate tokens/bps from /v1/admin/fee-tiers first.");
            return;
        }

        vm.startBroadcast();
        FeeCollector(fc).setTokenFeeBpsBatch(tokens, bps);
        vm.stopBroadcast();

        console2.log("Applied", tokens.length, "fee-tier overrides on", fc);
    }
}
