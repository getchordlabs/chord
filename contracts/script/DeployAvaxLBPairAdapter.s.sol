// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordLBPairAdapter} from "../src/chord/ChordLBPairAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord LB pair adapter on Avalanche (43114) for Pharaoh DLMM and register it.
/// @dev Factory 0xEb480050… = Pharaoh DLMM (Liquidity Book v2.2 pairs). Usage (from the Mac — the deployer owns
///      every proxy and never goes on the VPS):
///        forge script script/DeployAvaxLBPairAdapter.s.sol --rpc-url "$AVAX_RPC" --broadcast
contract DeployAvaxLBPairAdapterScript is Script {
    address constant PHARAOH_DLMM_FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 43114, "wrong chain: Avalanche only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        address[] memory factories = new address[](1);
        factories[0] = PHARAOH_DLMM_FACTORY;

        vm.startBroadcast(pk);
        ChordLBPairAdapter adapter = new ChordLBPairAdapter(ROUTER, factories);
        console2.log("ChordLBPairAdapter (Avalanche, Pharaoh DLMM):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
