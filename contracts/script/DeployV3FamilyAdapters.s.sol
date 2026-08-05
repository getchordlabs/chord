// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PancakeV3Adapter} from "../src/adapters/PancakeV3Adapter.sol";
import {V3DeadlineAdapter} from "../src/adapters/V3DeadlineAdapter.sol";
import {AlgebraAdapter} from "../src/adapters/AlgebraAdapter.sol";
import {UniV3GenericAdapter} from "../src/adapters/UniV3GenericAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @title Deploy the H1-hardened V3-family adapters (Monad 143)
/// @notice The 2026-08-05 audit's H1 fix gave every adapter an immutable NullRouter + `onlyRouter`
///         gate, which changed EVERY constructor. Adapters are immutable, so the fix ships as new
///         deployments + a registry swap — never an upgrade. This script covers the four V3-family
///         venues whose original deploys were done by hand with `cast send` and therefore left no
///         broadcast record to copy constructor args from.
/// @dev Constructor args were recovered from the LIVE adapters on mainnet (`ROUTER()`) and from the
///      engine's chain config (`packages/engine/src/chain.rs`), which is the single source of truth
///      for factories. Do not retype them from memory.
contract DeployV3FamilyAdaptersScript is Script {
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    /// @dev NullRouter proxy — the ONLY allowed caller of swap() (BaseAdapter H1 gate).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    // ── PancakeSwap V3 (the real one; engine `pancake_v3`) ───────────────────────────────────────
    // Router read from the live adapter 0x01ae5661…`ROUTER()`; factory from chain.rs.
    //
    // ⚠️ FLAVOR TRAP (cost one reverted mainnet swap on 2026-08-05): PancakeSwap's router on Monad
    // is a SwapRouter **v1** — `exactInputSingle` takes a `deadline` and its selector is 0x414bf389.
    // It is NOT SwapRouter02 (0x04e45aaf), which is what `PancakeV3Adapter` calls. Wiring
    // PancakeV3Adapter here compiles, quotes, passes the pool-provenance check, and then reverts
    // with bare `0x` at execution. The correct contract for this venue is `V3DeadlineAdapter`.
    // PROBE BEFORE WIRING ANY V3 FORK: `cast code <router>` and grep for 414bf389 vs 04e45aaf.
    // (Uniswap V3's router 0xfE31F71C IS SwapRouter02 — hence the two different adapters below.)
    address constant PCS_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant PCS_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    // ── Capricorn V3 (NadFun V1 graduation DEX; SwapRouter carries a deadline arg) ───────────────
    address constant CAPRICORN_ROUTER = 0xdac97b6a3951641B177283028A8f428332333071;
    address constant CAPRICORN_FACTORY = 0x6B5F564339DbAD6b780249827f2198a841FEB7F3;

    // ── Atlantis (Algebra V4 — pair-keyed, no fee tier, no router) ───────────────────────────────
    address constant ATLANTIS_FACTORY = 0x10253594A832f967994b44f33411940533302ACb;

    // ── Generic V3 forks (engine MONAD_GENERIC_V3_FORKS) ─────────────────────────────────────────
    address constant PANGOLIN_V3_FACTORY = 0x44805F92db5bB31B54632A55fc4b2B7E885B0e0e;
    address constant MONDAY_TRADE_FACTORY = 0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21;

    /// @dev ZERO init-code hash selects the factory's own `getPool`/`poolByPair` registry instead of
    ///      CREATE2 derivation. That is the SAFE lane: a wrong hash bricks a venue (every pool fails
    ///      provenance), while the registry lane asks the factory itself and cannot be wrong.
    bytes32 constant REGISTRY_LANE = bytes32(0);

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);

        vm.startBroadcast(pk);

        // V3DeadlineAdapter, NOT PancakeV3Adapter — see the FLAVOR TRAP note on PCS_ROUTER.
        V3DeadlineAdapter pcs =
            new V3DeadlineAdapter(NULL_ROUTER, PCS_ROUTER, PCS_FACTORY, REGISTRY_LANE);
        console2.log("V3DeadlineAdapter (pancake_v3)=", address(pcs));
        registry.addAdapter(address(pcs));

        V3DeadlineAdapter capricorn =
            new V3DeadlineAdapter(NULL_ROUTER, CAPRICORN_ROUTER, CAPRICORN_FACTORY, REGISTRY_LANE);
        console2.log("V3DeadlineAdapter (capricorn) =", address(capricorn));
        registry.addAdapter(address(capricorn));

        AlgebraAdapter atlantis = new AlgebraAdapter(NULL_ROUTER, ATLANTIS_FACTORY);
        console2.log("AlgebraAdapter (atlantis)     =", address(atlantis));
        registry.addAdapter(address(atlantis));

        UniV3GenericAdapter generic =
            new UniV3GenericAdapter(NULL_ROUTER, _factories(), _hashes(), _feeTiers());
        console2.log("UniV3GenericAdapter           =", address(generic));
        registry.addAdapter(address(generic));

        vm.stopBroadcast();
    }

    function _factories() internal pure returns (address[] memory f) {
        f = new address[](2);
        f[0] = PANGOLIN_V3_FACTORY;
        f[1] = MONDAY_TRADE_FACTORY;
    }

    function _hashes() internal pure returns (bytes32[] memory h) {
        h = new bytes32[](2);
        h[0] = REGISTRY_LANE;
        h[1] = REGISTRY_LANE;
    }

    /// @dev CREATION fee tiers, not live fees. PangolinV3 pools on Monad report `fee()` = 10 but were
    ///      created at 2500, so 2500 must be present or their provenance check falls through. Extra
    ///      tiers cannot weaken the check — each derives a different address and only an exact match
    ///      against the supplied pool is accepted.
    function _feeTiers() internal pure returns (uint24[] memory t) {
        t = new uint24[](5);
        t[0] = 100;
        t[1] = 500;
        t[2] = 2500;
        t[3] = 3000;
        t[4] = 10000;
    }
}
