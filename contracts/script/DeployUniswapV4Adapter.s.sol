// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy UniswapV4Adapter and register in AdapterRegistry
/// @dev Usage: forge script script/DeployUniswapV4Adapter.s.sol --rpc-url <RPC> --broadcast
contract DeployUniswapV4AdapterScript is Script {
    // Uniswap V4 on Monad mainnet
    address constant UNIVERSAL_ROUTER = 0x0D97Dc33264bfC1c226207428A79b26757fb9dc3;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // NullTerminal AdapterRegistry proxy on Monad
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy UniswapV4Adapter (immutable)
        UniswapV4Adapter adapter = new UniswapV4Adapter(UNIVERSAL_ROUTER, PERMIT2);
        console2.log("UniswapV4Adapter deployed:", address(adapter));

        // 2. Register in AdapterRegistry
        AdapterRegistry(ADAPTER_REGISTRY).addAdapter(address(adapter));
        console2.log("Adapter registered in AdapterRegistry");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== UniswapV4Adapter Deployment Complete ===");
        console2.log("Adapter:", address(adapter));
        console2.log("Registry:", ADAPTER_REGISTRY);
    }
}
