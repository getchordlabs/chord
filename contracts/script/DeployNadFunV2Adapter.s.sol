// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NadFunV2Adapter} from "../src/adapters/NadFunV2Adapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploys the H1-hardened NadFunV2Adapter (onlyRouter + M9 route binding).
/// The 2026-08-05 H1 sweep skipped this venue — the repo source was already hardened
/// but the LIVE address 0xC9dD7d25 stayed pre-H1 bytecode (no caller gate) while the
/// engine kept routing every nad.fun V2 bonding-curve buy through it.
contract DeployNadFunV2AdapterScript is Script {
    /// @dev nad.fun V2 curve router (its own quoter: getAmountOut(address,uint256,bool)).
    address constant V2_ROUTER = 0x8986C8fD44eb85294A725a7e61AF35E76bA26F91;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
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

        NadFunV2Adapter adapter = new NadFunV2Adapter(NULL_ROUTER, V2_ROUTER, WMON);
        console2.log("NadFunV2Adapter (H1):", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
