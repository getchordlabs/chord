// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordInfinityCLAdapter} from "../src/chord/ChordInfinityCLAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord Infinity CL adapter on BNB Chain (56) and register it.
/// @dev PancakeSwap Infinity: Vault 0x238a3588… (lock / sync / settle / take), CLPoolManager 0xa0FfB9c1… (swap), WBNB.
///      Usage (from the Mac — the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployBnbInfinityAdapter.s.sol --rpc-url "$BNB_RPC" --broadcast --gas-estimate-multiplier 200
contract DeployBnbInfinityAdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant INFINITY_VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant INFINITY_CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function run() external {
        require(block.chainid == 56, "wrong chain: BNB Chain only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));

        vm.startBroadcast(pk);
        ChordInfinityCLAdapter adapter = new ChordInfinityCLAdapter(ROUTER, INFINITY_VAULT, INFINITY_CL_POOL_MANAGER, WBNB);
        console2.log("ChordInfinityCLAdapter (BNB, PancakeSwap Infinity CL):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
