// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CurveAdapter} from "../src/adapters/CurveAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployCurveAdapterScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    /// @dev H1 provenance factory. This contract calls `exchange(uint256,…)` = the TWOCRYPTO flavor
    ///      (see the FLAVOR TRAP note in CurveAdapter.sol), so it must be pinned to the TwoCrypto
    ///      factory — address taken verbatim from that same NatSpec. StableSwap-NG pools belong to
    ///      CurveAdapterNG + factory 0x8271e06E…, NOT here.
    address constant CURVE_TWOCRYPTO_FACTORY = 0xe7FBd704B938cB8fe26313C3464D4b7B7348c88C;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        CurveAdapter adapter = new CurveAdapter(NULL_ROUTER, CURVE_TWOCRYPTO_FACTORY);
        console2.log("CurveAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
