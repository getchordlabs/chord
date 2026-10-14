// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordMetricV1Adapter} from "../src/chord/ChordMetricV1Adapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

interface IMetricV1FactoryView {
    function nextPoolIdx() external view returns (uint256);
}

/// @notice Deploy the Chord Metric v1 adapter and register it. The same script on every chain: Metric v1's factory
///         and SimpleRouter sit at the same addresses everywhere (CREATE2 / CREATE3), and so do the Chord router and
///         registry proxies.
/// @dev Usage (from the Mac — the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployMetricV1Adapter.s.sol --rpc-url "$RPC" --broadcast --gas-estimate-multiplier 200
///      (Monad: add --legacy.) Then: put the address in `chain.rs` `adapter_metric_v1` for that chain, deploy that
///      chain's engine, swap BOTH ways on mainnet, verify the contract.
///      `deployAs(deployer)` = the same body broadcast as an unlocked address, no key — fork tests and a local anvil
///      dry run only (ArbitrumForkTest deploys it right after the aligned stack, docs/arbitrum-contracts-deploy.md).
contract DeployMetricV1AdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant METRIC_V1_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address constant METRIC_V1_SIMPLE_ROUTER = 0x02201E6f13c41506c7Bb635d7543F98826229aB7;

    function run() external {
        _checks();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));

        vm.startBroadcast(pk);
        _deploy();
        vm.stopBroadcast();
    }

    /// @notice Fork-test / local-anvil entry: the SAME body broadcast as an unlocked `deployer` (no key).
    function deployAs(address deployer) external returns (address adapter) {
        _checks();
        vm.startBroadcast(deployer);
        adapter = _deploy();
        vm.stopBroadcast();
    }

    function _checks() internal view {
        // Chains where Metric v1 was read on-chain (factory + router + quoter code present): 2026-10-11, Arbitrum
        // 42161 on 2026-10-14 (WETH/USDC 0x4C9C6842… 19 WETH + 88.7k USDC; USDC/USD₮0 0x93F8Cc15… and 0x72aBbF3c…).
        uint256 id = block.chainid;
        require(
            id == 143 || id == 4663 || id == 8453 || id == 43114 || id == 56 || id == 42161,
            "Metric v1 not checked on this chain"
        );
        require(METRIC_V1_FACTORY.code.length > 0 && METRIC_V1_SIMPLE_ROUTER.code.length > 0, "Metric v1 not deployed here");
        require(IMetricV1FactoryView(METRIC_V1_FACTORY).nextPoolIdx() > 1, "factory has no pools");
        require(ROUTER.code.length > 0 && ADAPTER_REGISTRY.code.length > 0, "Chord proxies missing");
    }

    function _deploy() internal returns (address) {
        ChordMetricV1Adapter adapter = new ChordMetricV1Adapter(ROUTER, METRIC_V1_SIMPLE_ROUTER, METRIC_V1_FACTORY);
        console2.log("ChordMetricV1Adapter:", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        return address(adapter);
    }
}
