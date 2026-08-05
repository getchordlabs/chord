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
    /// @dev RESOLVED 2026-08-05: the 4 repo-seeded markets were replaced with the LIVE set the engine
    ///      is actually routing, read from `GET engine:3002/pools` (dex_id == "kuru") on the running
    ///      Monad engine. Deploying the 4-entry list would have made the other 9 quote and then revert
    ///      PoolNotAllowed. Re-read that endpoint before ANY redeploy — `backfill_kuru_markets`
    ///      discovers markets dynamically from api.kuru.io, so this list is a snapshot, and a market
    ///      added later needs a NEW adapter deployment + registry swap.
    function _markets() internal pure returns (address[] memory m) {
        m = new address[](13);
        m[0] = 0x065C9d28E428A0db40191a54d33d5b7c71a9C394;
        m[1] = 0x131A2e70A5b31a517A74b8c567149bc294470Da9;
        m[2] = 0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3;
        m[3] = 0x699AbC15308156E9a3AB89Ec7387e9CfE1c86A3b;
        m[4] = 0xa6aFD386135B7D41A6C40C525abC4A1019b0D132;
        m[5] = 0x40c49F171202F91ff5d2faE34c22dD2BFdD22aF0;
        m[6] = 0x851145eaeFdc37956B08dA829fa31722199F3f07;
        m[7] = 0x8cF49e35D73B19433FF4d4421637AABB680dc9Cc;
        m[8] = 0xCc46A703345a18C4Ef4BE20A447dC8613f0aebc4;
        m[9] = 0x5e5166f02b8F91AB80833270435172078F4178ca;
        m[10] = 0xe7A4f90369b48d8F5B61f2FD519eC563c11e4B2d;
        m[11] = 0xd2875972709ab1065D979261be99675d3B10B362;
        m[12] = 0x1CA0F16a316c3EE0Ff3CEC5382cAaD5648Ea512D;
    }
}
