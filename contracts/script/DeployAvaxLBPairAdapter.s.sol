// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordLBPairAdapter} from "../src/chord/ChordLBPairAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord LB pair adapter on Avalanche (43114) and register it.
/// @dev r1 (2026-10-02, 0xc37D0Da8…) pinned Pharaoh DLMM 0xEb480050… only. r2 (2026-10-14) pins it AND LFJ's Liquidity Book v2.1
///      factory 0x8e42f2F4… (born at block 28,371,397): v2.1 pairs share the v2.2 pair interface (swap(bool,address),
///      getSwapOut) and the factory's getLBPairInformation shape, so the same pair-direct adapter executes them. KyberSwap routes
///      v2.1 as `traderjoe-v21` (JOE, BTC.b, DAI.e). Usage (from the Mac — the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployAvaxLBPairAdapter.s.sol --rpc-url "$AVAX_RPC" --broadcast
contract DeployAvaxLBPairAdapterScript is Script {
    address constant PHARAOH_DLMM_FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    address constant LFJ_LB_V21_FACTORY = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 43114, "wrong chain: Avalanche only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        address[] memory factories = new address[](2);
        factories[0] = PHARAOH_DLMM_FACTORY;
        factories[1] = LFJ_LB_V21_FACTORY;

        vm.startBroadcast(pk);
        ChordLBPairAdapter adapter = new ChordLBPairAdapter(ROUTER, factories);
        console2.log("ChordLBPairAdapter (Avalanche, Pharaoh DLMM + LFJ LB v2.1):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
