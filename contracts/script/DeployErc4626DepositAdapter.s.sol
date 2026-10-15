// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChordErc4626DepositAdapter} from "../src/chord/ChordErc4626DepositAdapter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

interface IRouterWrapped {
    function wmon() external view returns (address);
}

/// @notice Deploy the Chord ERC-4626 deposit adapter and register it. The wrapped native coin is read from the
///         Chord router on the chain being deployed to, so the same script serves every chain.
/// @dev Usage (from the Mac — the deployer owns every proxy and never goes on the VPS):
///        forge script script/DeployErc4626DepositAdapter.s.sol --rpc-url "$RPC" --broadcast --gas-estimate-multiplier 200
///      (Monad: add --legacy.) Then: put the address in `chain.rs` `adapter_erc4626_deposit` for that chain together
///      with the vaults that were fork-tested there, deploy that chain's engine, buy each vault's token on mainnet,
///      verify the contract. The venue is BUY-ONLY by design (no redeem path).
contract DeployErc4626DepositAdapterScript is Script {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant ADAPTER_REGISTRY = 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f;

    function run() external {
        require(ROUTER.code.length > 0 && ADAPTER_REGISTRY.code.length > 0, "Chord proxies missing");
        address wrapped = IRouterWrapped(ROUTER).wmon();
        require(wrapped != address(0) && wrapped.code.length > 0, "router has no wrapped native");
        console2.log("Wrapped native:", wrapped);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console2.log("Deployer:", vm.addr(pk));

        vm.startBroadcast(pk);
        ChordErc4626DepositAdapter adapter = new ChordErc4626DepositAdapter(ROUTER, wrapped);
        console2.log("ChordErc4626DepositAdapter:", address(adapter));
        AdapterRegistry registry = AdapterRegistry(ADAPTER_REGISTRY);
        registry.addAdapter(address(adapter));
        require(registry.isApproved(address(adapter)), "addAdapter did not take");
        vm.stopBroadcast();
    }
}
