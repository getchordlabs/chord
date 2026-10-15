// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniV2GenericAdapter} from "../src/adapters/UniV2GenericAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Uniswap V2 adapter for Arc (5042) and register it.
/// @dev One factory: Uniswap V2 official (feeToSetter = Uniswap Safe, canonical 0.3 % — the three
///      V2 forks on Arc are NOT listed: fee getter unknown, see engine chain.rs ARC_V2_FACTORIES).
///      Usage (from packages/contracts, deployer = registry owner, funded with USDC):
///        DEPLOYER_PRIVATE_KEY=… forge script script/DeployArcV2Adapter.s.sol \
///          --rpc-url "$ARC_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      Then: engine chain.rs arc().adapter_univ2 = printed address, redeploy engine-arc, both-ways
///      mainnet swap on a V2 pair (docs/arc-contracts-deploy.md §6).
contract DeployArcV2AdapterScript is Script {
    address constant UNISWAP_V2_FACTORY = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    /// @dev Aligned-nonce proxies (same addresses as Monad / RH, docs/contracts-verification.md §Arc).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(block.chainid == 5042, "wrong chain: this script is Arc-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));

        address[] memory factories = new address[](1);
        factories[0] = UNISWAP_V2_FACTORY;

        vm.startBroadcast(deployerPrivateKey);
        UniV2GenericAdapter adapter = new UniV2GenericAdapter(NULL_ROUTER, factories);
        console2.log("UniV2GenericAdapter (Arc):", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        console2.log("Registered in AdapterRegistry:", ADAPTER_REGISTRY);
        vm.stopBroadcast();
    }
}
