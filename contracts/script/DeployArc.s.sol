// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {UniV3GenericAdapter} from "../src/adapters/UniV3GenericAdapter.sol";

/// @notice Deploy the NullTerminal core stack to Arc (chain 5042, Circle's stablecoin L1).
/// @dev docs/arc-contracts-deploy.md. Gas is paid in USDC (18-dec native unit). EIP-1559, NO --legacy.
///      Usage (from packages/contracts, deployer funded with native USDC on Arc):
///        DEPLOYER_PRIVATE_KEY=… TREASURY_ADDRESS=… forge script script/DeployArc.s.sol \
///          --rpc-url "$ARC_RPC_URL" --broadcast --gas-estimate-multiplier 200
///      SAME proxy addresses as Monad / RH (0x1B1Fee89… / 0x6c662296… / 0x6cf25d2a…) require the
///      deployer's Arc nonce to be exactly the nonce it had on Monad at step 1 AND the identical
///      deploy order below (registryImpl → registryProxy → routerImpl → routerProxy → collectorImpl
///      → collectorProxy). Check `cast nonce <deployer> --rpc-url $ARC_RPC_URL` BEFORE broadcasting;
///      a mismatch does not break the deploy, it only breaks address alignment (then update
///      NULL_ROUTER_ADDRESS_ARC etc. and TX_CHAINS[5042]).
contract DeployArcScript is Script {
    // ⚠️ Arc has NO wrapped-native contract. The gas token is USDC; its ERC-20 view is the 6-dec
    // predeploy below, while the native unit is 18-dec. NullRouter's `wmon` is used for wrap
    // (deposit()) / unwrap (withdraw()) of NATIVE input/output — neither exists on the predeploy,
    // so on Arc the router serves ERC-20 ↔ ERC-20 swaps only; a native-in or native-out route
    // reverts at the wrap call. The engine's Arc slice never emits native legs (V4 is off).
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    // Uniswap V3 factory on Arc (sdk-core ARC_ADDRESSES, owner = Uniswap Safe, 10,943 pools).
    address constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;

    // Tiered fee model as on Monad/RH: default = new-token tier, majors overridden to 0.
    uint16 constant DEFAULT_FEE_BPS = 25;
    uint16 constant REFERRAL_SHARE_BPS = 5000; // 50% referral split

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        console2.log("Deployer nonce (must match Monad step-1 nonce for aligned proxies):", vm.getNonce(deployer));
        require(block.chainid == 5042, "wrong chain: expected Arc 5042");

        vm.startBroadcast(deployerPrivateKey);

        // NONCE MAP (must reproduce Monad/RH for identical proxy addresses — read on-chain 2026-09-16
        // by cast compute-address over the deployer's nonces on both chains):
        //   0 registry impl · 1 registry PROXY · 2 (any contract) · 3 router impl · 4 router PROXY ·
        //   5 (any contract) · 6 collector PROXY · 7+ config calls.
        // So the FeeCollector impl goes at nonce 2 and the adapter at nonce 5 — both constructor-only
        // deploys that need nothing but addresses already known. The proxies then land exactly on
        // 0x6cf25d2a… / 0x1B1Fee89… / 0x6c662296…. Anything that changes this order (a failed tx, a
        // console-only run that still broadcasts, an extra `new`) shifts every later address.

        // 1. AdapterRegistry (UUPS proxy) — nonce 0 impl, nonce 1 proxy
        AdapterRegistry registryImpl = new AdapterRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(AdapterRegistry.initialize, (deployer))
        );
        AdapterRegistry registry = AdapterRegistry(address(registryProxy));

        // 2. FeeCollector impl — nonce 2 (the "any contract" slot)
        FeeCollector feeCollectorImpl = new FeeCollector();

        // 3. NullRouter (UUPS proxy) — nonce 3 impl, nonce 4 proxy. Placeholder feeCollector, wired in
        //    step 6. `executor` slot is deprecated (storage-layout only) — address(0), never re-add.
        NullRouter routerImpl = new NullRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(NullRouter.initialize, (
                deployer,
                USDC,       // "wmon" — the ERC-20 view of the gas token; wrap/unwrap unsupported (see above)
                address(0), // executor — deprecated slot
                address(1), // placeholder feeCollector
                address(registry)
            ))
        );
        NullRouter router = NullRouter(payable(address(routerProxy)));

        // 4. UniV3GenericAdapter — nonce 5. Pool-direct swap for the Uniswap V3 factory (registry
        //    lane: initCodeHash ZERO ⇒ factory.getPool provenance). One factory in this slice;
        //    adding a fork later = NEW adapter (immutable) + registry swap.
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = UNISWAP_V3_FACTORY;
        bytes32[] memory v3InitCodeHashes = new bytes32[](1);
        uint24[] memory feeTiers = new uint24[](4);
        feeTiers[0] = 100;
        feeTiers[1] = 500;
        feeTiers[2] = 3000;
        feeTiers[3] = 10000;
        UniV3GenericAdapter v3Adapter = new UniV3GenericAdapter(address(router), v3Factories, v3InitCodeHashes, feeTiers);

        // 5. FeeCollector proxy — nonce 6
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

        // 6. Wire the real FeeCollector, approve the adapter — nonces 7, 8
        router.setFeeCollector(address(feeCollector));
        registry.addAdapter(address(v3Adapter));

        // 7. Fee tiers: the dollar and euro stables → 0 bps.
        address[] memory zeroFee = new address[](2);
        zeroFee[0] = USDC;
        zeroFee[1] = EURC;
        uint16[] memory zeroBps = new uint16[](2);
        feeCollector.setTokenFeeBpsBatch(zeroFee, zeroBps);

        vm.stopBroadcast();

        console2.log("=== NullTerminal on Arc (5042) ===");
        console2.log("AdapterRegistry proxy:", address(registry));
        console2.log("AdapterRegistry impl: ", address(registryImpl));
        console2.log("NullRouter proxy:     ", address(router));
        console2.log("NullRouter impl:      ", address(routerImpl));
        console2.log("FeeCollector proxy:   ", address(feeCollector));
        console2.log("FeeCollector impl:    ", address(feeCollectorImpl));
        console2.log("UniV3GenericAdapter:  ", address(v3Adapter));
    }
}
