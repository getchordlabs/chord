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

    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MetricAdapter metric = new MetricAdapter(NULL_ROUTER, METRIC_SWAP_ROUTER, _metricPools());
        console2.log("MetricAdapter:", address(metric));

        LfjPoeAdapter poe = new LfjPoeAdapter(NULL_ROUTER, _poePools());
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

    /// @dev H1 provenance ALLOWLIST — Metric OMM exposes no factory/registry view we can validate an
    ///      extraData pool against on Monad, so the pool set is fixed at construction (no setter, no
    ///      owner). VERBATIM from packages/engine/src/state/pool_syncer.rs (`metric:` block) —
    ///      "exactly 3 pools, token order verified on-chain via getImmutables 2026-07-22".
    ///      A 4th pool later = NEW adapter deployment + registry swap.
    function _metricPools() internal pure returns (address[] memory p) {
        p = new address[](3);
        p[0] = 0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0; // WMON/USDC
        p[1] = 0x2D82AC42334b394A9a8d8f097d61DC1c6B065Fd8; // WBTC/USDC
        p[2] = 0x354D92279cA0190fF275095fE6A2a6989BAa66Fb; // WETH/USDC
    }

    /// @dev H1 provenance ALLOWLIST — no POE factory/registry view is verified on Monad, so the pool
    ///      set is fixed at construction. VERBATIM from pool_syncer.rs (`lfj_poe:` block), tokenX/
    ///      tokenY verified on-chain via getTokens() 2026-07-22. A 3rd pool = NEW adapter deployment.
    function _poePools() internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = 0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f; // WMON/USDC
        p[1] = 0x06C526964bFB06c6BAAC17fF91a36EC671382171; // AUSD/USDC
    }
}
