// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {V3DeadlineAdapter} from "../src/adapters/V3DeadlineAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @title Re-deploy the `pancake_v3` adapter with the CORRECT router flavor (Monad 143)
/// @notice One-off correction. `DeployV3FamilyAdapters.s.sol` first wired this venue to
///         `PancakeV3Adapter`, which calls SwapRouter02's `exactInputSingle` (selector 0x04e45aaf).
///         PancakeSwap's router on Monad is a SwapRouter **v1**: its `exactInputSingle` carries a
///         `deadline` and hashes to 0x414bf389. The mismatch is invisible until execution — the
///         adapter deploys, registers, quotes, and passes pool provenance, then the swap reverts
///         with a bare `0x`. Caught by the both-ways mainnet check on 2026-08-05.
/// @dev The flavor is decidable off-chain in one command, so do it before wiring any V3 fork:
///        cast code <router> --rpc-url $MONAD_RPC_URL | grep -c 414bf389   # v1 (deadline)
///        cast code <router> --rpc-url $MONAD_RPC_URL | grep -c 04e45aaf   # SwapRouter02
///      Same bug class as the Curve NG/TwoCrypto `exchange` trap in the root CLAUDE.md.
contract DeployPancakeV3FixScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant PCS_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant PCS_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    /// @dev ZERO = ask the factory's own `getPool` registry instead of deriving CREATE2. Verified
    ///      live: PCS_FACTORY.getPool(USDC, WMON, 500) == 0x63e48B72… , the pool the engine routes.
    bytes32 constant REGISTRY_LANE = bytes32(0);

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        V3DeadlineAdapter adapter =
            new V3DeadlineAdapter(NULL_ROUTER, PCS_ROUTER, PCS_FACTORY, REGISTRY_LANE);
        console2.log("V3DeadlineAdapter (pancake_v3) =", address(adapter));

        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Registered");

        vm.stopBroadcast();
    }
}
