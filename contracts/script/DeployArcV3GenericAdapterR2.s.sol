// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniV3GenericAdapter} from "../src/adapters/UniV3GenericAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Arc (5042) UniV3GenericAdapter round 2 — the Uniswap V3 factory PLUS Synthra's own V3
///         factory (0x6307fc23…, GeckoTerminal "synthra-arc", 187 pools / $5.8M a day on 2026-09-18).
///         The adapter's factory list is immutable, so a new fork = a new adapter + registry add;
///         the engine's `adapter_generic_v3` then moves to this address (chain.rs arc()).
///         Both factories use the REGISTRY lane (initCodeHash zero ⇒ factory.getPool provenance):
///         Synthra's pool 0xee765f55… (NIGHT/USDC 1 %) resolves through getPool, and its swap
///         callback is `synthraV3SwapCallback` — same (int256,int256,bytes) ABI, served by the
///         adapter's fallback. The previous adapter 0xd55fe37e… stays approved for the official pools
///         already routed until the engine flips; remove it only after both-ways passes here.
///         Usage (from packages/contracts, deployer = registry owner, funded with USDC):
///           set -a; source .env; set +a
///           forge script script/DeployArcV3GenericAdapterR2.s.sol --rpc-url $ARC_RPC --broadcast --gas-estimate-multiplier 200
contract DeployArcV3GenericAdapterR2 is Script {
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address constant SYNTHRA_V3_FACTORY = 0x6307fc239C7964942c1BfFE51930E55606619c74;

    function run() external {
        require(block.chainid == 5042, "wrong chain: this script is Arc-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));

        address[] memory factories = new address[](2);
        factories[0] = UNISWAP_V3_FACTORY;
        factories[1] = SYNTHRA_V3_FACTORY;
        bytes32[] memory hashes = new bytes32[](2); // zero = registry lane for both
        uint24[] memory feeTiers = new uint24[](4);
        feeTiers[0] = 100;
        feeTiers[1] = 500;
        feeTiers[2] = 3000;
        feeTiers[3] = 10000;

        vm.startBroadcast(deployerPrivateKey);
        UniV3GenericAdapter adapter = new UniV3GenericAdapter(NULL_ROUTER, factories, hashes, feeTiers);
        console2.log("UniV3GenericAdapter (r2, Uniswap + Synthra):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        console2.log("Registered in AdapterRegistry:", ADAPTER_REGISTRY);
        vm.stopBroadcast();
    }
}
