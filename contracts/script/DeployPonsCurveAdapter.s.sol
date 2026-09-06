// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PonsCurveAdapter} from "../src/adapters/PonsCurveAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

interface INullRouterRegistryView {
    function registry() external view returns (address);
}

/// @notice Deploy PonsCurveAdapter on Robinhood Chain (4663) and register it in the RH AdapterRegistry.
/// @dev Usage (from packages/contracts):
///        DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployPonsCurveAdapter.s.sol \
///          --rpc-url <RH_RPC> --broadcast --legacy --gas-estimate-multiplier 200
///      Then: packages/engine/src/chain.rs robinhood().adapter_pons_curve = <logged address>,
///      `deploy/vps.sh engine-rh`, and verify BOTH directions on a live curve through the prod API
///      (buy WETH→token, sell token→WETH) before calling the venue live — CLAUDE.md DEX rule.
///
///      Every constant is an RH address recovered from the live deployment (NOT copied from Monad —
///      the deployer nonces line up across chains, so a Monad constant is a plausible-looking
///      landmine here). The chain guard + registry cross-check below refuse a mis-pointed run.
contract DeployPonsCurveAdapterScript is Script {
    // NullRouter proxy on RH — same address as Monad by aligned nonces, DIFFERENT implementation.
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    // WETH9 on RH (SwapRouter02.WETH9()) — the engine's wrapped native for 4663.
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    // Pons V2 launch factory (docs.ponsfamily.com/docs/v2; on-chain: curves report factory() == this).
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    // A known Pons V2 launch (PENKE) — used only as a read-only provenance smoke test post-deploy.
    address constant PENKE_TOKEN = 0xcB240a8632569A5D49ccf1FC0Ca0Fa1F940B9799;
    address constant PENKE_CURVE = 0xc779806A87ADBb96f2c2C4056988B8189A01ac6f;

    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain 4663");
        require(
            INullRouterRegistryView(NULL_ROUTER).registry() == ADAPTER_REGISTRY,
            "router.registry() != ADAPTER_REGISTRY - constants are from different deployments"
        );
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        PonsCurveAdapter adapter = new PonsCurveAdapter(NULL_ROUTER, PONS_FACTORY, WETH9);
        console2.log("PonsCurveAdapter:", address(adapter));

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "adapter not approved");

        vm.stopBroadcast();

        // Provenance smoke test (view): the factory must name PENKE's curve for PENKE. If Pons ever
        // replaces the launchpad "as a whole set" (their words), this is the line that goes red.
        address seen = adapter.curveOf(PENKE_TOKEN);
        console2.log("curveOf(PENKE):", seen, seen == PENKE_CURVE ? "(ok)" : "(MISMATCH - do not route)");

        console2.log("");
        console2.log("NEXT: chain.rs robinhood().adapter_pons_curve =", address(adapter));
        console2.log("      deploy/vps.sh engine-rh, then both-ways mainnet swap on a live curve.");
    }
}
