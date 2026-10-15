// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {NullRouter} from "../src/NullRouter.sol";

/// @notice Deploy NullTerminal core contracts to Monad mainnet
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url https://rpc.monad.xyz --broadcast --verify
contract DeployScript is Script {
    // Monad WMON
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // Protocol fee: 5 bps (0.05%)
    uint16 constant FEE_BPS = 5;
    // Referral share: 50% of fee
    uint16 constant REFERRAL_SHARE_BPS = 5000;

    function run() external {
        // Chain guard (2026-08-05). Every constant below is a MONAD address, but the deployer's
        // nonces happen to line up across chains, so the registry/router constants are ACCIDENTALLY
        // valid addresses on Robinhood 4663 too. Without this line, pointing --rpc-url at RH would
        // deploy a Monad-configured adapter and addAdapter it into the LIVE RH registry: it registers
        // cleanly and then reverts on every swap.
        require(block.chainid == 143, "wrong chain: this script is Monad-only");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // 1. Deploy AdapterRegistry (UUPS proxy)
        // ============================================================
        AdapterRegistry registryImpl = new AdapterRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(AdapterRegistry.initialize, (deployer))
        );
        AdapterRegistry registry = AdapterRegistry(address(registryProxy));
        console2.log("AdapterRegistry proxy:", address(registry));
        console2.log("AdapterRegistry impl:", address(registryImpl));

        // ============================================================
        // 2. (removed 2026-08-05) NullExecutor is NOT deployed any more.
        //    It was the delegatecall leg-executor; it left the swap path on 2026-03-20 (44-gas
        //    revert on Monad) and NullRouter has called adapters directly ever since. The router's
        //    `executor` slot only survives for UUPS storage-layout compatibility, so it is
        //    initialized to address(0) below. Do NOT re-add: deploying it advertises a core
        //    contract that does nothing, and BaseAdapter's onlyRouter gate rejects it anyway.
        // ============================================================

        // ============================================================
        // 3. Deploy NullRouter (UUPS proxy) — temporary feeCollector
        //    We need router address for FeeCollector init, so deploy router first
        //    with a placeholder, then update after FeeCollector is deployed.
        // ============================================================

        // Deploy FeeCollector with a placeholder router (will update after)
        // Actually: deploy router first, use its address for FeeCollector

        NullRouter routerImpl = new NullRouter();

        // We need to predict the FeeCollector proxy address, or deploy in 2 steps.
        // Simpler: deploy router, then FeeCollector with router address, then set feeCollector on router.

        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(NullRouter.initialize, (
                deployer,
                WMON,
                address(0), // executor — deprecated slot, storage-layout only (see step 2)
                address(1), // placeholder feeCollector — will update
                address(registry)
            ))
        );
        NullRouter router = NullRouter(payable(address(routerProxy)));
        console2.log("NullRouter proxy:", address(router));
        console2.log("NullRouter impl:", address(routerImpl));

        // ============================================================
        // 4. Deploy FeeCollector (UUPS proxy) — now we have router address
        // ============================================================
        FeeCollector feeCollectorImpl = new FeeCollector();
        ERC1967Proxy feeCollectorProxy = new ERC1967Proxy(
            address(feeCollectorImpl),
            abi.encodeCall(FeeCollector.initialize, (
                deployer,
                treasury,
                address(router),
                FEE_BPS,
                REFERRAL_SHARE_BPS
            ))
        );
        FeeCollector feeCollector = FeeCollector(address(feeCollectorProxy));
        console2.log("FeeCollector proxy:", address(feeCollector));
        console2.log("FeeCollector impl:", address(feeCollectorImpl));

        // ============================================================
        // 5. Update Router with real FeeCollector
        // ============================================================
        router.setFeeCollector(address(feeCollector));
        console2.log("Router feeCollector updated");

        vm.stopBroadcast();

        // ============================================================
        // Summary
        // ============================================================
        console2.log("");
        console2.log("=== NullTerminal Deployment Complete ===");
        console2.log("AdapterRegistry:", address(registry));
        console2.log("NullRouter:     ", address(router));
        console2.log("FeeCollector:   ", address(feeCollector));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Deploy adapters (UniswapV4Adapter, etc.)");
        console2.log("  2. Register adapters: AdapterRegistry.addAdapter(addr)");
        console2.log("  3. Update packages/shared/src/constants.ts with addresses");
    }
}
