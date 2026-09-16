// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniV2TaxSafeAdapter} from "../src/adapters/UniV2TaxSafeAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the fee-on-transfer-safe Uniswap V2 adapter for Arc (5042) and register it.
/// @dev Replaces UniV2GenericAdapter 0x623F61a2… as the routed V2 adapter (that one stays approved
///      but unrouted — every official-factory token on Arc carries a 1–2 % transfer tax and it
///      priced off amountIn → `UniswapV2: K`). Usage:
///        DEPLOYER_PRIVATE_KEY=… forge script script/DeployArcV2TaxSafeAdapter.s.sol \
///          --rpc-url "$ARC_RPC_URL" --broadcast --gas-estimate-multiplier 200
contract DeployArcV2TaxSafeAdapterScript is Script {
    address constant UNISWAP_V2_FACTORY = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 5042, "wrong chain: this script is Arc-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        address[] memory factories = new address[](1);
        factories[0] = UNISWAP_V2_FACTORY;

        vm.startBroadcast(deployerPrivateKey);
        UniV2TaxSafeAdapter adapter = new UniV2TaxSafeAdapter(NULL_ROUTER, factories);
        console2.log("UniV2TaxSafeAdapter (Arc):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        console2.log("Registered in AdapterRegistry:", ADAPTER_REGISTRY);
        vm.stopBroadcast();
    }
}
