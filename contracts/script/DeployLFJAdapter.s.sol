// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LFJAdapter} from "../src/adapters/LFJAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployLFJAdapterScript is Script {
    address constant LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    /// @dev H1 provenance: LBFactory — `getLBPairInformation(tokenIn, tokenOut, binStep)` must name a
    ///      real pair before the router is approved. Matches engine chain.rs `lfj_factory`.
    address constant LB_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
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

        LFJAdapter adapter = new LFJAdapter(NULL_ROUTER, LB_ROUTER, LB_FACTORY);
        console2.log("LFJAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
