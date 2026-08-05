// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KuruAdapter} from "../src/adapters/KuruAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

contract DeployKuruAdapterScript is Script {
    address constant KURU_ROUTER = 0xd651346d7c789536ebf06dc72aE3C8502cd695CC;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy on Monad — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        KuruAdapter adapter = new KuruAdapter(NULL_ROUTER, KURU_ROUTER, WMON, _markets());
        console2.log("KuruAdapter:", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }

    /// @dev H1 provenance ALLOWLIST — Kuru has no on-chain registry view to validate an extraData
    ///      market against, so the routable market set is fixed at construction (no setter, no
    ///      owner). Copied VERBATIM from the seed in packages/engine/src/state/pool_syncer.rs
    ///      (`kuru:` block).
    ///
    ///      ⚠️ TODO(owner): CONFIRM THIS LIST IMMEDIATELY BEFORE DEPLOY — this is the allowlist that
    ///      hurts most. The engine discovers ~10 routable Kuru markets DYNAMICALLY from
    ///      api.kuru.io/api/v1/markets (`backfill_kuru_markets`), and only these 4 are seeded in the
    ///      repo. Every discovered-but-unlisted market (cbBTC/USDC, XAUt0/USDC, WETH/USDC,
    ///      WMON/USDT0, CHOG/MON, shMON/MON, …) will quote and then revert PoolNotAllowed on
    ///      execution. Pull the live market list and extend this array before broadcasting; adding a
    ///      market afterwards = NEW adapter deployment + registry swap.
    function _markets() internal pure returns (address[] memory m) {
        m = new address[](4);
        m[0] = 0x065C9d28E428A0db40191a54d33d5b7c71a9C394; // MON/USDC
        m[1] = 0x131A2e70A5b31a517A74b8c567149bc294470Da9; // MON/AUSD
        m[2] = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3; // MON/AUSD (second book)
        m[3] = 0x699AbC15308156E9a3AB89Ec7387e9CfE1c86A3b; // AUSD/USDC
    }
}
