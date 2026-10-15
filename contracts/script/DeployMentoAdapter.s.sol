// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MentoAdapter} from "../src/adapters/MentoAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployMentoAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev Mento protocol Router on Monad (docs.mento.org, defaultFactory verified on-chain).
    address constant MENTO_ROUTER = 0x4861840C2EfB2b98312B0aE34d86fD73E8f9B6f6;
    /// @dev H1 provenance: the ONLY pool factory this adapter will route through. FPMMFactory —
    ///      verified on-chain as MENTO_ROUTER.defaultFactory() (MentoAdapter.sol NatSpec) and equal
    ///      to engine chain.rs `mento_fpmm_factory`, which is what the engine puts in extraData.
    ///      extraData must match this EXACTLY or swap() reverts FactoryNotPinned.
    address constant MENTO_FPMM_FACTORY = 0xa849b475FE5a4B5C9C3280152c7a1945b907613b;
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

        MentoAdapter adapter = new MentoAdapter(NULL_ROUTER, MENTO_ROUTER, MENTO_FPMM_FACTORY);
        console2.log("MentoAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
