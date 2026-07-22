// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MetricAdapter} from "../src/adapters/MetricAdapter.sol";
import {LfjPoeAdapter} from "../src/adapters/LfjPoeAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy BOTH MetricAdapter (Metric OMM) and LfjPoeAdapter (LFJ POE OraclePool) and
///         register them in AdapterRegistry.
/// @dev Usage:
///        DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployMetricPoeAdapters.s.sol \
///          --rpc-url "$MONAD_RPC_URL" --broadcast --legacy
///      (Monad chain 143 needs --legacy; if broadcast flakes, fall back to
///       `forge create src/adapters/MetricAdapter.sol:MetricAdapter --constructor-args <ROUTER> --legacy`
///       / `forge create src/adapters/LfjPoeAdapter.sol:LfjPoeAdapter --legacy`
///       + `cast send <REGISTRY> "addAdapter(address)" <ADAPTER> --legacy` per adapter.)
///
///      Then copy the logged addresses into packages/engine/src/router/quoter.rs ONLY:
///        ADAPTER_METRIC  = <MetricAdapter>
///        ADAPTER_LFJ_POE = <LfjPoeAdapter>
///      and redeploy the engine. Both venues quote via eth_call in quoter.rs — math_quoter.rs has
///      no consts for them. extraData for both = abi.encode(address pool), per-market.
contract DeployMetricPoeAdaptersScript is Script {
    // Metric OMM legacy shared SwapRouter on Monad mainnet (bytecode-selector-verified).
    address constant METRIC_SWAP_ROUTER = 0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5;

    // NullTerminal AdapterRegistry (UUPS) — onlyOwner gating on addAdapter.
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MetricAdapter metric = new MetricAdapter(METRIC_SWAP_ROUTER);
        console2.log("MetricAdapter:", address(metric));

        LfjPoeAdapter poe = new LfjPoeAdapter();
        console2.log("LfjPoeAdapter:", address(poe));

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(metric));
        registry.addAdapter(address(poe));
        console2.log("Both adapters registered in AdapterRegistry.");

        // Sanity: both must read approved now.
        require(registry.isApproved(address(metric)), "metric not approved");
        require(registry.isApproved(address(poe)), "poe not approved");

        vm.stopBroadcast();

        console2.log("");
        console2.log("NEXT: set these in packages/engine/src/router/quoter.rs ONLY, then redeploy the engine:");
        console2.log("  ADAPTER_METRIC  =", address(metric));
        console2.log("  ADAPTER_LFJ_POE =", address(poe));
        console2.log("(math_quoter.rs has no consts for these venues - both quote via eth_call in quoter.rs.)");
    }
}
