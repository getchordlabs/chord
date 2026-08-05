// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PancakeV3Adapter} from "../src/adapters/PancakeV3Adapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy PancakeV3Adapter and register
contract DeployPancakeV3AdapterScript is Script {
    address constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    /// @dev H1 provenance: the V3 factory SWAP_ROUTER_02 settles against. Router↔factory MUST be the
    ///      same deployment or every swap fails PoolNotCanonical — this pair (router 0xfE31F71C…,
    ///      factory 0x204FAca1…) is the one documented in PancakeV3Adapter.sol's own NatSpec, and
    ///      0x204FAca1… is the UNISWAP V3 factory (root CLAUDE.md: this router/adapter lineage was
    ///      historically mislabelled "PCS V3"; real PancakeSwap V3 factory is 0x0BFbCF9f… and it has
    ///      its OWN router). ⚠️ TODO(owner): if this deployment is meant to serve real PancakeSwap V3
    ///      rather than Uniswap V3, swap in the PCS router + factory 0x0BFbCF9f… before broadcasting.
    address constant V3_FACTORY = 0x204FAca1764B154221e35c0d20aBb3c525710498;

    /// @dev ZERO = use the factory's own `getPool` registry for provenance instead of CREATE2
    ///      derivation. Deliberate: no verified pool init-code hash for this factory exists anywhere
    ///      in this repo, and the adapter NatSpec is explicit that guessing one bricks every swap —
    ///      "pass zero" is the documented, equally-authoritative option (the factory is pinned either
    ///      way). Only replace with a hash that has been independently verified on-chain.
    bytes32 constant POOL_INIT_CODE_HASH = bytes32(0);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        PancakeV3Adapter adapter =
            new PancakeV3Adapter(NULL_ROUTER, SWAP_ROUTER_02, V3_FACTORY, POOL_INIT_CODE_HASH);
        console2.log("PancakeV3Adapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
