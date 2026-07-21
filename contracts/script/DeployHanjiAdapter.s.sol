// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HanjiAdapter} from "../src/adapters/HanjiAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy HanjiAdapter and register it in AdapterRegistry.
/// @dev Usage:
///        DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployHanjiAdapter.s.sol \
///          --rpc-url "$MONAD_RPC_URL" --broadcast --legacy
///      (Monad chain 143 needs --legacy; if broadcast flakes, fall back to
///       `forge create src/adapters/HanjiAdapter.sol:HanjiAdapter --constructor-args <WMON> --legacy`
///       + `cast send <REGISTRY> "addAdapter(address)" <ADAPTER> --legacy`.)
///
///      Then copy the logged address into packages/engine/src/router/math_quoter.rs:
///        ADAPTER_HANJI = <HanjiAdapter>
///      and redeploy the engine. Hanji is math-path-only: quoter.rs intentionally has NO
///      ADAPTER_HANJI const — the eth_call quote path Errs by design (same pattern as
///      Kuru/Atlantis hops). extraData = abi.encode(address fastQuoterProxy) — per-market,
///      e.g. MON/USDC proxy 0x1aed222dda944a87703c918745b11be13f8eef10.
contract DeployHanjiAdapterScript is Script {
    // Canonical WMON on Monad mainnet — the adapter re-wraps native venue payouts into this.
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // NullTerminal AdapterRegistry (UUPS) — onlyOwner gating on addAdapter.
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        HanjiAdapter adapter = new HanjiAdapter(WMON);
        console2.log("HanjiAdapter:", address(adapter));

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        console2.log("HanjiAdapter registered in AdapterRegistry.");

        // Sanity: must read approved now.
        require(registry.isApproved(address(adapter)), "hanji not approved");

        vm.stopBroadcast();

        console2.log("");
        console2.log("NEXT: set this in packages/engine/src/router/math_quoter.rs, then redeploy the engine:");
        console2.log("  ADAPTER_HANJI =", address(adapter));
        console2.log("(quoter.rs has no Hanji const on purpose - the eth_call path Errs by design; math-path-only.)");
    }
}
