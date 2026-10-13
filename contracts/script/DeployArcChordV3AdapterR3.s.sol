// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordV3Adapter} from "../src/chord/ChordAdapters.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Arc (5042) V3 adapter round 3 — the any-fork adapter (`ChordV3Adapter` = `UniV3AnyForkAdapter`) with four
///         factories pinned: Uniswap V3 and Synthra (what r2 `0x55049D78…` serves) plus the two KyberSwap routes USDC / EURC
///         through and Chord did not (2026-10-13, board #234): `aero-cl` 0xb89df768… (its USDC / EURC pool holds ~30x the
///         liquidity of Uniswap V3's) and `archery-v3` 0xc481038c…. Both new factories key their registry on TICK SPACING:
///         `getPool(address,address,int24)` names the pool, `getPool(address,address,uint24)` answers zero on the first and
///         reverts on the second, and both emit Slipstream's `PoolCreated(token0, token1, tickSpacing, pool)`. That is the
///         lane `UniV3GenericAdapter` (r1, r2) does not have, hence the any-fork contract. All four on the REGISTRY lane
///         (initCodeHash zero: the pinned factory itself is asked). The factory list is immutable, so this is a new adapter
///         + registry add; the engine's `adapter_generic_v3` then moves here (chain.rs arc()). r2 stays approved until the
///         engine has flipped and both-ways has passed.
///         Provenance on the real factories: test/fork/ArcSlipstreamForkTest.t.sol. The swap itself cannot run in a local
///         fork (Arc's USDC predeploy), so it is proven on mainnet: docs/contracts-verification.md, Arc.
///         Usage (from packages/contracts, deployer = registry owner, funded with USDC):
///           set -a; source .env; set +a
///           forge script script/DeployArcChordV3AdapterR3.s.sol --rpc-url $ARC_RPC --broadcast --gas-estimate-multiplier 200
contract DeployArcChordV3AdapterR3 is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address constant SYNTHRA_V3_FACTORY = 0x6307fc239C7964942c1BfFE51930E55606619c74;
    address constant AERO_CL_FACTORY = 0xb89Df768aF2CFE637ceB352c587Fe8edAf491d03;
    address constant ARCHERY_FACTORY = 0xC481038C013FE96F38CE7A2dC417b2B1B78b16A4;

    function run() external {
        require(block.chainid == 5042, "wrong chain: this script is Arc-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));

        address[] memory factories = new address[](4);
        factories[0] = UNISWAP_V3_FACTORY;
        factories[1] = SYNTHRA_V3_FACTORY;
        factories[2] = AERO_CL_FACTORY;
        factories[3] = ARCHERY_FACTORY;
        bytes32[] memory hashes = new bytes32[](4); // zero = registry lane for all four
        uint24[] memory feeTiers = new uint24[](4);
        feeTiers[0] = 100;
        feeTiers[1] = 500;
        feeTiers[2] = 3000;
        feeTiers[3] = 10000;

        vm.startBroadcast(deployerPrivateKey);
        ChordV3Adapter adapter = new ChordV3Adapter(ROUTER, factories, hashes, feeTiers);
        console2.log("ChordV3Adapter (r3: Uniswap + Synthra + aero-cl + archery):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        console2.log("Registered in AdapterRegistry:", ADAPTER_REGISTRY);
        vm.stopBroadcast();
    }
}
