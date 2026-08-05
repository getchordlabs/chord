// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NullOrderBook} from "../src/NullOrderBook.sol";

/// Deploys NullOrderBook and whitelists the keeper.
///
/// PREREQUISITE: the dff96f8 NullRouter upgrade (multi-hop continuity +
/// native-out overload) must be live before keepers execute multi-hop or
/// native-out fills.
///
/// Env: DEPLOYER_PRIVATE_KEY (owner), KEEPER_ADDRESS (fill executor EOA),
///      ORDERBOOK_ORACLE + ORDERBOOK_MAX_DEVIATION_BPS (audit H3 — see below; pass
///      ORDERBOOK_ORACLE=0x0 to deploy deliberately unbounded).
/// Run:  forge script script/DeployOrderBook.s.sol --rpc-url $MONAD_RPC_URL \
///         --broadcast --legacy
/// (forge broadcast is flaky on Monad — fall back to `forge create` + `cast send`.)
///
/// ⚠️ AUDIT H3 — the oracle bound is the ONLY thing capping keeper skim. A whitelisted keeper
/// picks the route and the book accepts whatever `received` comes back above the user's limit
/// price; the `oracle` + `maxDeviationBps` pair is what stops a keeper routing through a pool it
/// controls and pocketing the difference. `NullOrderBook`'s constructor deliberately leaves both
/// unset (pointing at a WRONG reference is worse than none), which means an unconfigured book runs
/// limit-price-floor-only. This script therefore forces the choice to be explicit rather than
/// letting it be forgotten — the failure mode is silent, and it is a funds bug, not an outage.
contract DeployOrderBookScript is Script {
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address owner = vm.addr(deployerPrivateKey);

        // Read BEFORE broadcasting: a missing var should abort with nothing deployed, not leave a
        // half-configured book on-chain.
        address oracle = vm.envAddress("ORDERBOOK_ORACLE");
        uint16 maxDeviationBps = uint16(vm.envUint("ORDERBOOK_MAX_DEVIATION_BPS"));
        require(
            oracle == address(0) || maxDeviationBps > 0,
            "H3: oracle set but ORDERBOOK_MAX_DEVIATION_BPS=0 disables the bound"
        );

        vm.startBroadcast(deployerPrivateKey);

        NullOrderBook book = new NullOrderBook(NULL_ROUTER, WMON, owner);
        console2.log("NullOrderBook:", address(book));

        book.setKeeper(keeper, true);
        console2.log("Keeper whitelisted:", keeper);

        if (oracle != address(0)) {
            book.setOracle(oracle, maxDeviationBps);
            console2.log("Oracle bound set:", oracle, maxDeviationBps);
        } else {
            console2.log("!! ORACLE BOUND DISABLED: fills are limit-price-floor-only (audit H3).");
            console2.log("!! Keeper skim is uncapped beyond the user's limit price. Deliberate?");
        }

        vm.stopBroadcast();
    }
}
