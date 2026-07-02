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
/// Env: DEPLOYER_PRIVATE_KEY (owner), KEEPER_ADDRESS (fill executor EOA).
/// Run:  forge script script/DeployOrderBook.s.sol --rpc-url $MONAD_RPC_URL \
///         --broadcast --legacy
/// (forge broadcast is flaky on Monad — fall back to `forge create` + `cast send`.)
contract DeployOrderBookScript is Script {
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address owner = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        NullOrderBook book = new NullOrderBook(NULL_ROUTER, WMON, owner);
        console2.log("NullOrderBook:", address(book));

        book.setKeeper(keeper, true);
        console2.log("Keeper whitelisted:", keeper);

        vm.stopBroadcast();
    }
}
