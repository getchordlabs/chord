// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordAlgebraIntegralAdapter} from "../src/chord/ChordAlgebraIntegralAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Chord Algebra Integral adapter on Avalanche (Blackhole CL), Base (Hydrex + QuickSwap V4) or BNB
///         (THENA V3) and register it. One script, the venue list is picked by chain id.
/// @dev Entries are (factory, deployer); deployer 0 = default pools (`poolByPair`), else `customPoolByPair(deployer, …)`.
///      The lists come from every `CustomPool` (topic 0x8a5f030f) / `Pool` (0x91ccaa7a) event each factory emitted
///      (scan 2026-10-02) — `createCustomPool` is role-gated in the factory, so each deployer below is one the venue
///      authorised. Ordered by pool count (the lookup walks in order). The list is immutable: a new deployer = a new
///      adapter. Usage (from the Mac): forge script script/DeployAlgebraIntegralAdapter.s.sol --rpc-url "$RPC" --broadcast
contract DeployAlgebraIntegralAdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    // Avalanche — Blackhole CL: no default WAVAX/USDC pool; liquidity sits in custom-deployer pools.
    address constant BLACKHOLE_CL_FACTORY = 0x512eb749541B7cf294be882D636218c84a5e9E5F;
    // Base
    address constant HYDREX_FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E;
    address constant QUICKSWAP_V4_FACTORY = 0xC5396866754799B9720125B104AE01d935Ab9C7b;
    // BNB — THENA V3 (Algebra, default pools only)
    address constant THENA_V3_FACTORY = 0x30055F87716d3DFD0E5198C27024481099fB4A98;

    function venues() public view returns (address[] memory fs, address[] memory ds) {
        if (block.chainid == 43114) {
            fs = new address[](7);
            ds = new address[](7);
            ds[0] = 0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584; // 37 pools
            ds[1] = 0xDcFccf2e8c4EfBba9127B80eAc76c5A122125d29; // 23
            ds[2] = 0x0AFf494476Dc74CF7BB5Dd005c2B1fE7Be76efA2; // 2
            ds[3] = 0x43c4b7BD4C173992C6711c631859A2EAC84BF8Db; // 1
            ds[4] = 0x58b05074D52D1a84D8FfDAddA3c1b652e8C56994; // 1
            ds[5] = 0xf9221dE143A0E57c324bF2a0f281e605e845D767; // 1
            ds[6] = address(0); // 2 default pools
            for (uint256 i = 0; i < 7; i++) fs[i] = BLACKHOLE_CL_FACTORY;
        } else if (block.chainid == 8453) {
            fs = new address[](3);
            ds = new address[](3);
            fs[0] = HYDREX_FACTORY; // default pools only
            fs[1] = QUICKSWAP_V4_FACTORY;
            fs[2] = QUICKSWAP_V4_FACTORY;
            ds[2] = 0xdA97EfAa1576FA251D18dcdddFC51A1dE218189f; // 8 custom pools
        } else if (block.chainid == 56) {
            fs = new address[](1);
            ds = new address[](1);
            fs[0] = THENA_V3_FACTORY;
        } else {
            revert("wrong chain: Avalanche, Base or BNB only");
        }
    }

    function run() external {
        (address[] memory fs, address[] memory ds) = venues();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        console2.log("Chain:", block.chainid, "venues:", fs.length);

        vm.startBroadcast(pk);
        ChordAlgebraIntegralAdapter adapter = new ChordAlgebraIntegralAdapter(ROUTER, fs, ds);
        console2.log("ChordAlgebraIntegralAdapter:", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
