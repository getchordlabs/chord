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

        // 2. NullExecutor (immutable, stateless) — registry PINNED at construction (audit L9).
        NullExecutor executor = new NullExecutor(address(registry));

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
        //    abi.encode(pool)) + register it.
        //    H1: the adapter now only accepts pools it can PROVE came from one of the factories
        //    pinned here. `nullRouter` = the proxy deployed in step 3 (onlyRouter entrypoint gate).
        //    Every initCodeHash is left ZERO on purpose = the REGISTRY lane (factory.getPool /
        //    poolByPair). None of these forks' creation-code hashes are verified anywhere in this
        //    repo, and the adapter's own NatSpec is explicit: never guess a hash, pass zero.
        address[] memory v3Factories = _rhV3Factories();
        bytes32[] memory v3InitCodeHashes = new bytes32[](v3Factories.length); // all zero → registry lane
        UniV3GenericAdapter v3Adapter =
            new UniV3GenericAdapter(address(router), v3Factories, v3InitCodeHashes, _rhV3FeeTiers());
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

    /// @dev Every V3-family factory the engine routes on 4663, VERBATIM from
    ///      packages/engine/src/chain.rs (`uniswap_v3_factory` + `RH_GENERIC_V3_FORKS`) — that file
    ///      is the discovery source of truth, so a fork missing here is a fork whose pools the
    ///      adapter will reject with PoolNotCanonical. Adding a fork later = NEW adapter deployment
    ///      + registry swap (adapters are immutable); keep the two lists in lockstep.
    ///
    ///      ⚠️ TODO(owner): `up_v3` (0x1ac9dB4a…, last entry) is a SLIPSTREAM fork — its registry is
    ///      tickSpacing-keyed `getPool(address,address,int24)`, which is NEITHER of the two shapes
    ///      the adapter probes (`getPool(…,uint24)` / `poolByPair`). Its pools will therefore fail
    ///      provenance unless a VERIFIED initCodeHash is pinned for it. Confirm before deploy:
    ///      either supply that hash (see _rhV3Factories caller) or accept that up_v3 stops routing.
    function _rhV3Factories() internal pure returns (address[] memory f) {
        f = new address[](13);
        f[0] = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // uniswap_v3 (chain.rs uniswap_v3_factory)
        f[1] = 0xEce6eCd61177336ea6Fb9b17937AC439D85EE20B; // giga_v3
        f[2] = 0x0Ec554F0BfF0Be6C99d1e95C8015bb0950f6A2C7; // swaphood_v3
        f[3] = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865; // pcs_v3
        f[4] = 0x46c695d1Eba2411824C22DF59b8F488493a72aa5; // graildex_v3
        f[5] = 0xd479E71C45aEB1E846A7B549c346D62fE77B39bA; // uniswap_v3_b
        f[6] = 0xE0c4ceb92d08CA985bB70fe0a22fEb121A9854A8; // ramses_v3
        f[7] = 0xEa561E058313B96011e5070Ca7d0f027A44E3748; // robinswap_v3
        f[8] = 0x8ed4510ab87Bb64E1Be0f54ae0c5534629257a44; // based_v3
        f[9] = 0xE51960f1B45f1C9FB6D166E6a884F866fC70433B; // sushiswap_v3
        f[10] = 0xcA8152ab363dC2F23BB30f6c6c2678028E7cF30a; // uniswap_v3_e
        f[11] = 0x869c5ae05AaE4fd8D6D63F35107f14e8260b8c33; // rh_v3_f
        f[12] = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3; // up_v3 (slipstream — see TODO above)
    }

    /// @dev Candidate CREATION fee tiers probed when a pool's live `fee()` is not its registry key
    ///      (dynamic-fee forks). Union of chain.rs `v3_fee_tiers` + `v3_fork_fee_tiers` for 4663.
    function _rhV3FeeTiers() internal pure returns (uint24[] memory t) {
        t = new uint24[](5);
        t[0] = 100;
        t[1] = 500;
        t[2] = 2500;
        t[3] = 3000;
        t[4] = 10000;
    }
}
