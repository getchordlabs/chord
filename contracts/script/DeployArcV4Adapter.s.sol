// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4NativeViewAdapter} from "../src/adapters/UniswapV4NativeViewAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

/// @notice Deploy the Uniswap V4 adapter for Arc (5042) and register it.
/// @dev Arc's gas token is USDC: 18-dec native, 6-dec ERC-20 view predeploy 0x3600…0000 (a VIEW of
///      the native balance, not a wrapper — measured 2026-09-16). The adapter scales by 1e12 instead
///      of wrapping. Usage (from packages/contracts, deployer = registry owner, funded with USDC):
///        DEPLOYER_PRIVATE_KEY=… forge script script/DeployArcV4Adapter.s.sol \
///          --rpc-url "$ARC_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      EIP-1559, no --legacy. Then: engine chain.rs arc().adapter_v4 = printed address, redeploy
///      engine-arc, both-ways mainnet swap on a hooked native pool (docs/arc-contracts-deploy.md §5).
contract DeployArcV4AdapterScript is Script {
    /// @dev Uniswap V4 PoolManager on Arc (same address as RH; 980+ pools, 2026-09-14 recon).
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @dev USDC ERC-20 predeploy — the 6-dec view of the 18-dec gas token.
    address constant USDC_VIEW = 0x3600000000000000000000000000000000000000;
    uint8 constant SCALE_POW10 = 12;
    /// @dev Aligned-nonce proxies (same addresses as Monad / RH, docs/contracts-verification.md §Arc).
    address constant NULL_ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        // The proxy constants are ALSO valid on Monad/RH (aligned nonces) — pointing --rpc-url at
        // another chain would register an Arc-configured adapter into a live registry there.
        require(block.chainid == 5042, "wrong chain: this script is Arc-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        UniswapV4NativeViewAdapter adapter =
            new UniswapV4NativeViewAdapter(NULL_ROUTER, POOL_MANAGER, USDC_VIEW, SCALE_POW10);
        console2.log("UniswapV4NativeViewAdapter:", address(adapter));

        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        console2.log("Registered in AdapterRegistry:", ADAPTER_REGISTRY);

        vm.stopBroadcast();
    }
}
