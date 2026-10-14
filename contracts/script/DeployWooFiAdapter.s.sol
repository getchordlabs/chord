// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordWooFiAdapter} from "../src/chord/ChordWooFiAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

interface IWooPPV2View {
    function quoteToken() external view returns (address);
    function paused() external view returns (bool);
}

/// @notice Deploy the Chord WOOFi adapter and register it. The same script on every chain: WOOFi's WooPPV2 sits at the
///         same address everywhere it runs, and so do the Chord router and registry proxies.
/// @dev Usage (from the Mac — the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployWooFiAdapter.s.sol --rpc-url "$RPC" --broadcast --gas-estimate-multiplier 200
///      (Monad: add --legacy.) Then: both-ways mainnet swap through the router, the address into `chain.rs`
///      `adapter_woofi` for that chain, deploy that chain's engine, verify the contract.
///      `deployAs(deployer)` = the same body broadcast as an unlocked address, no key — fork tests / local anvil only.
contract DeployWooFiAdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;
    address constant WOO_PP = 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4;

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
        // Chains where WooPPV2 was read on-chain 2026-10-14 (code, quoteToken = the chain's main stable, not paused).
        uint256 id = block.chainid;
        require(id == 143 || id == 43114 || id == 56 || id == 8453 || id == 42161, "WooPPV2 not checked on this chain");
        require(WOO_PP.code.length > 0, "WooPPV2 not deployed here");
        require(IWooPPV2View(WOO_PP).quoteToken() != address(0), "WooPPV2 has no quote token");
        require(!IWooPPV2View(WOO_PP).paused(), "WooPPV2 is paused");
        require(ROUTER.code.length > 0 && ADAPTER_REGISTRY.code.length > 0, "Chord proxies missing");
    }

    function _deploy() internal returns (address) {
        ChordWooFiAdapter adapter = new ChordWooFiAdapter(ROUTER, WOO_PP);
        console2.log("ChordWooFiAdapter:", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        return address(adapter);
    }
}
