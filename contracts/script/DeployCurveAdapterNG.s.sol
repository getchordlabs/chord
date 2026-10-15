// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CurveAdapterNG} from "../src/adapters/CurveAdapterNG.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployCurveAdapterNGScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    /// @dev H1 provenance factory: Curve StableSwap-NG factory (verbatim from CurveAdapterNG.sol's
    ///      NatSpec). Both live seeded pools — BTC 3-pool 0xd2634e05…, LST 4-pool 0x74d80ee4…
    ///      (packages/engine/src/dex/curve.rs) — must answer `get_n_coins` > 0 on this factory or
    ///      the adapter fails closed on them.
    address constant CURVE_STABLESWAP_NG_FACTORY = 0x8271e06E5887FE5ba05234f5315c19f3Ec90E8aD;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        CurveAdapterNG adapter = new CurveAdapterNG(NULL_ROUTER, CURVE_STABLESWAP_NG_FACTORY);
        console2.log("CurveAdapterNG:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
