// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordDodoV2Adapter} from "../src/chord/ChordDodoV2Adapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

interface IDodoV2FactoryView {
    function getDODOPool(address baseToken, address quoteToken) external view returns (address[] memory machines);
}

/// @notice Deploy the Chord DODO V2 adapter and register it. The DPPFactory of each chain comes from DODO's own deploy config
///         (github.com/DODOEX/contractV2 config/<chain>-config.js) and was read on-chain 2026-10-14: `getDODOPool(WETH, USDC)`
///         returns the market-maker pool KyberSwap routes as `dodo-dpp` (Avalanche 0xb300709b…, Arbitrum 0x1666ea6e…).
/// @dev Usage (from the Mac — the deployer owns every proxy):
///        forge script script/DeployDodoV2Adapter.s.sol --rpc-url "$RPC" --broadcast --slow --gas-estimate-multiplier 200
///      Then: both-ways mainnet swap through the router, the address into `chain.rs` `dodo` for that chain, the engine deploy.
contract DeployDodoV2AdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function factories() public view returns (address[] memory fs) {
        fs = new address[](1);
        if (block.chainid == 43114) fs[0] = 0xb7865a5ceE051d35B09A48b624D7057d3362655a; // DPPFactory, Avalanche
        else if (block.chainid == 42161) fs[0] = 0xa6Cf3d163358aF376ec5e8B7Cc5e102a05FdE63D; // DPPFactory, Arbitrum
        else if (block.chainid == 56) fs[0] = 0xd9CAc3D964327e47399aebd8e1e6dCC4c251DaAE; // DPPFactory, BNB Chain
        else if (block.chainid == 8453) fs[0] = 0xc0F9553Df63De5a97Fe64422c8578D0657C360f7; // DPPFactory, Base
        else revert("DODO V2 factory not checked on this chain");
    }

    function run() external {
        address[] memory fs = factories();
        require(fs[0].code.length > 0, "factory has no code");
        require(ROUTER.code.length > 0 && ADAPTER_REGISTRY.code.length > 0, "Chord proxies missing");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));
        vm.startBroadcast(pk);
        ChordDodoV2Adapter adapter = new ChordDodoV2Adapter(ROUTER, fs);
        console2.log("ChordDodoV2Adapter:", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
