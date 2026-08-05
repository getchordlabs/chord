// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NadFunPairAdapter} from "../src/adapters/NadFunPairAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @title Deploy the H1-hardened nad.fun DEX adapter (Monad 143)
/// @notice ⚠️ The venue that nad.fun **V2** tokens graduate into is served by `NadFunPairAdapter`,
///         which swaps DIRECTLY on the pair. `NadFunDEXAdapter` (router-based) was SUPERSEDED
///         2026-07-06 — the DEXRouter's internal registry reads transient-empty for a token that has
///         just graduated, so router-based swaps revert. `DeployNadFunAdapters.s.sol` still deploys
///         the superseded contract; that script must NOT be used to refresh this venue.
/// @dev Engine field: `adapter_nadfun_dex` (packages/engine/src/chain.rs).
contract DeployNadFunPairAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    /// @dev nad.fun V2 pair factory (engine `nadfun_dex_factory`) — `getPair` is the provenance
    ///      oracle the adapter checks a supplied pool against.
    address constant NADFUN_FACTORY = 0xA25b13127e63ddae6d0b35570FF3D39dBD621001;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        NadFunPairAdapter adapter = new NadFunPairAdapter(NULL_ROUTER, WMON, NADFUN_FACTORY);
        console2.log("NadFunPairAdapter (nadfun_dex) =", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
