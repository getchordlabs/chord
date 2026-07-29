// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {NullExecutor} from "../src/NullExecutor.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {UniV3GenericAdapter} from "../src/adapters/UniV3GenericAdapter.sol";

/// @notice Deploy the NullTerminal core stack to Robinhood Chain (4663).
/// @dev docs/robinhood-expansion-prompt.md §7e. Arbitrum-stack: NO --legacy, EIP-1559 fine.
///      Usage:
///        forge script script/DeployRH.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///          --broadcast --gas-estimate-multiplier 200
///      Verify (Blockscout, NOT Sourcify):
///        forge verify-contract <addr> <Contract> --verifier blockscout \
///          --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployRHScript is Script {
    // Wrapped native on 4663 — WETH9 (on-chain-verified via SwapRouter02.WETH9(), spec §2).
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    // Majors on RH v1 — 0 bps tier. AAPL (xStock) also 0 bps until the legal read (§7e: never
    // charge fees on securities before understanding the rules).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    // Default (meme-tier) fee — same tiered model as Monad: default 25 bps, majors overridden to 0.
    uint16 constant DEFAULT_FEE_BPS = 25;
    uint16 constant REFERRAL_SHARE_BPS = 5000; // 50% referral split

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain 4663");

        vm.startBroadcast(deployerPrivateKey);

        // 1. AdapterRegistry (UUPS proxy)
        AdapterRegistry registryImpl = new AdapterRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(AdapterRegistry.initialize, (deployer))
        );
        AdapterRegistry registry = AdapterRegistry(address(registryProxy));

        // 2. NullExecutor (immutable, stateless)
        NullExecutor executor = new NullExecutor();

        // 3. NullRouter (UUPS proxy) — placeholder feeCollector, updated in step 5
        NullRouter routerImpl = new NullRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(NullRouter.initialize, (
                deployer,
                WETH9,
                address(executor),
                address(1), // placeholder feeCollector
                address(registry)
            ))
        );
        NullRouter router = NullRouter(payable(address(routerProxy)));

        // 4. FeeCollector (UUPS proxy)
        FeeCollector feeCollectorImpl = new FeeCollector();
        ERC1967Proxy feeCollectorProxy = new ERC1967Proxy(
            address(feeCollectorImpl),
            abi.encodeCall(FeeCollector.initialize, (
                deployer,
                treasury,
                address(router),
                DEFAULT_FEE_BPS,
                REFERRAL_SHARE_BPS
            ))
        );
        FeeCollector feeCollector = FeeCollector(address(feeCollectorProxy));

        // 5. Wire the real FeeCollector
        router.setFeeCollector(address(feeCollector));

        // 6. UniV3GenericAdapter (pool-direct swap + transient-storage callback gate; extraData =
        //    abi.encode(pool)) + register it
        UniV3GenericAdapter v3Adapter = new UniV3GenericAdapter();
        registry.addAdapter(address(v3Adapter));

        // 7. Fee tiers: majors + xStocks-pending-legal → 0 bps
        address[] memory zeroFee = new address[](3);
        zeroFee[0] = WETH9;
        zeroFee[1] = USDG;
        zeroFee[2] = AAPL;
        uint16[] memory zeroBps = new uint16[](3);
        feeCollector.setTokenFeeBpsBatch(zeroFee, zeroBps);

        vm.stopBroadcast();

        console2.log("=== NullTerminal on Robinhood Chain (4663) ===");
        console2.log("AdapterRegistry proxy:", address(registry));
        console2.log("AdapterRegistry impl: ", address(registryImpl));
        console2.log("NullExecutor:         ", address(executor));
        console2.log("NullRouter proxy:     ", address(router));
        console2.log("NullRouter impl:      ", address(routerImpl));
        console2.log("FeeCollector proxy:   ", address(feeCollector));
        console2.log("FeeCollector impl:    ", address(feeCollectorImpl));
        console2.log("UniV3GenericAdapter:  ", address(v3Adapter));
    }
}
