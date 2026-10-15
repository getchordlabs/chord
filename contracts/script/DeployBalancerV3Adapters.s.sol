// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BalancerV3Adapter} from "../src/adapters/BalancerV3Adapter.sol";
import {BalancerV3BoostedAdapter} from "../src/adapters/BalancerV3BoostedAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy BOTH Balancer V3 adapters (simple + boosted) and register them in AdapterRegistry.
/// @dev Usage:
///        DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployBalancerV3Adapters.s.sol \
///          --rpc-url <MONAD_RPC> --broadcast --legacy
///      Then copy the two logged addresses into packages/engine/src/router/quoter.rs:
///        ADAPTER_BALANCER         = <BalancerV3Adapter>
///        ADAPTER_BALANCER_BOOSTED = <BalancerV3BoostedAdapter>
///      and redeploy the engine. Both adapters self-check ROUTER.getVault() == VAULT in their constructor.
contract DeployBalancerV3AdaptersScript is Script {
    // Balancer V3 on Monad (verified vs balancer/balancer-deployments, tag v3, + on-chain).
    address constant VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant AGGREGATOR_ROUTER = 0xc3ccacE87f6d3A81724075ADcb5ddd85a8A1bB68; // simple single-pool
    address constant AGGREGATOR_BATCH_ROUTER = 0x7A2535f5fB47b8e44c02Ef5D9990588313fe8F05; // boosted/buffer

    // NullTerminal AdapterRegistry (UUPS) — onlyOwner gating on addAdapter.
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    // NullRouter proxy on Monad — the ONLY contract allowed to call swap() (BaseAdapter H1 gate).
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

        BalancerV3Adapter simple = new BalancerV3Adapter(NULL_ROUTER, VAULT, AGGREGATOR_ROUTER);
        console2.log("BalancerV3Adapter (simple):       ", address(simple));

        BalancerV3BoostedAdapter boosted =
            new BalancerV3BoostedAdapter(NULL_ROUTER, VAULT, AGGREGATOR_BATCH_ROUTER);
        console2.log("BalancerV3BoostedAdapter (boosted):", address(boosted));

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(simple));
        registry.addAdapter(address(boosted));
        console2.log("Both adapters registered in AdapterRegistry.");

        // Sanity: both must read approved now.
        require(registry.isApproved(address(simple)), "simple not approved");
        require(registry.isApproved(address(boosted)), "boosted not approved");

        vm.stopBroadcast();

        console2.log("");
        console2.log("NEXT: set these in packages/engine/src/router/quoter.rs, then redeploy the engine:");
        console2.log("  ADAPTER_BALANCER         =", address(simple));
        console2.log("  ADAPTER_BALANCER_BOOSTED =", address(boosted));
    }
}
