// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkSwapHelpers} from "./ForkSwapHelpers.sol";
import {DeployArbitrumScript} from "../../script/DeployArbitrum.s.sol";
import {DeployMetricV1AdapterScript} from "../../script/DeployMetricV1Adapter.s.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";
import {UniV3AnyForkAdapter} from "../../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2TaxSafeAdapter} from "../../src/adapters/UniV2TaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../../src/adapters/UniswapV4Adapter.sol";

interface IV2Router02 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface IMetricV1QuoterA {
    function quoteLiveExactInSingle(address pool, address sender, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
        external
        returns (uint256 amountIn_, uint256 amountOut);
}

/// @title ArbitrumForkTest — docs/arbitrum-contracts-deploy.md §6
/// @notice Deploys the Arbitrum One (42161) stack with `DeployArbitrumScript` AS the real deployer EOA on a fork,
///         proves the proxies align with every other chain and that each contract lands on Base's address number,
///         then round-trips real pools through the router on every venue the engine routes first: Uniswap V3,
///         PancakeSwap V3 (pool-direct, fallback callback), SushiSwap V3, Uniswap V2, SushiSwap V2, Uniswap V4 (native
///         and ERC20 pools), the router's native ETH legs, and the Metric v1 follow-up adapter. Name ends in
///         `ForkTest` ⇒ CI skips it. Run (QuickNode-style RPC; pin a block so reruns hit forge's RPC cache):
///           forge test --match-contract ArbitrumForkTest --fork-url "$ARB_RPC" --fork-block-number <N> -vv
contract ArbitrumForkTest is ForkSwapHelpers {
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant USDCE = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548; // not on the zero-fee list
    address constant STATE_VIEW = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;

    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SUSHI_V3_FACTORY = 0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e;
    address constant UNISWAP_V2_FACTORY = 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9;
    address constant SUSHI_V2_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant V4_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24; // factory() = Uniswap V2
    address constant SUSHI_V2_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; // factory() = SushiSwap V2

    // Pools (factory.getPool / getPair read 2026-10-14; WETH held by the pool in brackets).
    address constant UNI_V3_WETH_USDC_500 = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // 8,777 WETH
    address constant PCS_V3_WETH_USDC_500 = 0xd9e2a1a61B6E61b275cEc326465d417e52C1b95c; // 192 WETH
    address constant PCS_V3_WETH_USDC_100 = 0x7fCDC35463E3770c2fB992716Cd070B63540b947; // 124 WETH
    address constant SUSHI_V3_WETH_USDC_500 = 0xf3Eb87C1F6020982173C908E7eB31aA66c1f0296; // 60 WETH
    address constant UNI_V2_WETH_USDC = 0xF64Dfe17C8b87F012FCf50FbDA1D62bfA148366a; // 10.8 WETH
    address constant SUSHI_V2_WETH_USDCE = 0x905dfCD5649217c42684f23958568e533C711Aa3; // 34.4 WETH (Sushi's deepest)

    // Metric v1 (same addresses on every chain).
    address constant METRIC_V1_QUOTER = 0x803Dd787ef9734c34696877ca6F20194fBcBFbF8;
    address constant METRIC_V1_SIMPLE_ROUTER = 0x02201E6f13c41506c7Bb635d7543F98826229aB7;
    address constant METRIC_V1_WETH_USDC = 0x4C9C68429C76cC299Bc89483BD1DFb382F146071; // 19.1 WETH + 88.7k USDC
    address constant METRIC_V1_USDC_USDT0 = 0x93F8Cc15ec02D4151BF38677Bb5eDcA449bF0Ccd; // 15.8k USDC + 49.9k USD₮0

    address v3Adapter;
    address v2Adapter;
    address v4Adapter;

    function setUp() public {
        _forkIfNeeded(42161, "ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc");
        stateView = STATE_VIEW;
        wrapped = WETH;
        _deployStack(new DeployArbitrumScript());
        v3Adapter = stack.adapters[0];
        v2Adapter = stack.adapters[1];
        v4Adapter = stack.adapters[2];
    }

    // ── deployment shape ─────────────────────────────────────────────────────────────────────────

    /// Same proxies as every chain; same deployer + same nonces ⇒ every contract lands on Base's address NUMBER
    /// (Base broadcast 2026-10-01: docs/contracts-verification.md §Base). Bytecode differs where the constructor
    /// arguments differ (factory lists, PoolManager, WETH) — read a contract per chain, never across.
    function test_addresses_alignWithEveryChain_andBaseNumbers() public view {
        assertEq(address(stack.registry), 0x6Cf25d2af1A58d7094B0ac253aE616A8e1F2Ea3f, "registry proxy");
        assertEq(address(router), 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a, "router proxy");
        assertEq(address(stack.feeCollector), 0x6C66229675FD9cEDa9A9B2Ea2BD983B3d8255834, "collector proxy");
        assertEq(stack.registryImpl, 0x9121AFF4B2968f048659A29a3923B53c95087Fec, "registry impl (nonce 0)");
        assertEq(stack.feeCollectorImpl, 0x4bD6cc6bFa321971F96DB60e64Aa9C86cCff2f7E, "collector impl (nonce 2)");
        assertEq(stack.routerImpl, 0x1cd8CeED960dE0c9787295c8F1BF278D4A36698c, "router impl (nonce 3)");
        assertEq(v3Adapter, 0xd55fe37e30435cF15fe2C7fcAAF1aBf19d13b195, "V3 adapter (nonce 5)");
        assertEq(v2Adapter, 0xa61C202C4c989a1724E1B432C96A9f064856574d, "V2 adapter (nonce 9)");
        assertEq(v4Adapter, 0xFE82b7714c36083AB518067f03680C59ac57840a, "V4 adapter (nonce 10)");
        assertEq(stack.registry.adapterCount(), 3, "registry holds exactly the three new adapters");
        // 3 impls/proxies ×2 + 3 adapters + setFeeCollector + 3 addAdapter + fee batch = 14 txs
        assertEq(vm.getNonce(DEPLOYER), 14, "deployer nonce after the run");

        // pinned venues
        assertEq(UniV3AnyForkAdapter(v3Adapter).factories(0), UNISWAP_V3_FACTORY, "V3 factory 0");
        assertEq(UniV3AnyForkAdapter(v3Adapter).factories(1), PANCAKE_V3_FACTORY, "V3 factory 1");
        assertEq(UniV3AnyForkAdapter(v3Adapter).factories(2), SUSHI_V3_FACTORY, "V3 factory 2");
        assertEq(UniV2TaxSafeAdapter(v2Adapter).factoriesLength(), 2, "V2 factory count");
        assertEq(UniV2TaxSafeAdapter(v2Adapter).factories(0), UNISWAP_V2_FACTORY, "V2 factory 0");
        assertEq(UniV2TaxSafeAdapter(v2Adapter).factories(1), SUSHI_V2_FACTORY, "V2 factory 1");
        assertEq(address(UniswapV4Adapter(payable(v4Adapter)).POOL_MANAGER()), V4_POOL_MANAGER, "V4 PoolManager");
        assertEq(UniswapV4Adapter(payable(v4Adapter)).WMON(), WETH, "V4 wrapped native");
        assertEq(router.wmon(), WETH, "router wmon = WETH");

        // fees: 5 bps default from the first block (owner 2026-10-02), 0 on stables / majors, 50 % referral share
        assertEq(stack.feeCollector.feeBps(), 5, "default fee");
        assertEq(stack.feeCollector.referralShareBps(), 5000, "referral share");
        assertEq(stack.feeCollector.treasury(), DEPLOYER, "treasury = deployer (Monad / Base precedent)");
        assertEq(stack.feeCollector.feeBpsFor(USDC), 0, "USDC");
        assertEq(stack.feeCollector.feeBpsFor(USDT0), 0, "USDT0");
        assertEq(stack.feeCollector.feeBpsFor(USDCE), 0, "USDC.e");
        assertEq(stack.feeCollector.feeBpsFor(DAI), 0, "DAI");
        assertEq(stack.feeCollector.feeBpsFor(WETH), 0, "WETH (and native ETH out)");
        assertEq(stack.feeCollector.feeBpsFor(WBTC), 0, "WBTC");
        assertEq(stack.feeCollector.feeBpsFor(ARB), 5, "unlisted token pays the default");
    }

    function test_H1_everyAdapterRejectsDirectCalls() public {
        _assertNotRouterGate(v3Adapter, abi.encode(UNI_V3_WETH_USDC_500));
        _assertNotRouterGate(v2Adapter, abi.encode(UNI_V2_WETH_USDC));
        _assertNotRouterGate(v4Adapter, abi.encode(_ethUsdcKey()));
    }

    // ── V3 family (ChordV3Adapter) ───────────────────────────────────────────────────────────────

    function test_uniswapV3_WETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("Uniswap V3 WETH/USDC 0.05%", v3Adapter, UNI_V3_WETH_USDC_500), WETH, USDC, 0.5 ether, 100);
    }

    /// PancakeSwap V3 calls back `pancakeV3SwapCallback` — served by the adapter's fallback; pool CREATE2'd by the
    /// PoolDeployer, authenticated through factory.getPool.
    function test_pancakeV3_WETH_USDC_500() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("PancakeSwap V3 WETH/USDC 0.05%", v3Adapter, PCS_V3_WETH_USDC_500), WETH, USDC, 0.5 ether, 100);
    }

    function test_pancakeV3_WETH_USDC_100() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("PancakeSwap V3 WETH/USDC 0.01%", v3Adapter, PCS_V3_WETH_USDC_100), WETH, USDC, 0.5 ether, 100);
    }

    function test_sushiV3_WETH_USDC_500() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("SushiSwap V3 WETH/USDC 0.05%", v3Adapter, SUSHI_V3_WETH_USDC_500), WETH, USDC, 0.5 ether, 100);
    }

    /// A pool no pinned factory created is refused (a V3 pool of a factory we did not pin: Camelot V3 / Algebra).
    function test_v3_unpinnedFactoryPool_refused() public {
        address camelotWethUsdc = 0xB1026b8e7276e7AC75410F1fcbbe21796e8f7526; // Camelot V3 poolByPair(WETH, USDC)
        deal(WETH, user, 0.1 ether);
        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WETH, tokenOut: USDC, amountIn: 0.1 ether, extraData: abi.encode(camelotWethUsdc)
        });
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, camelotWethUsdc));
        router.swap(WETH, USDC, 0.1 ether, 1, block.timestamp + 600, step, address(0));
        vm.stopPrank();
    }

    // ── V2 (ChordV2Adapter, 0.3 %) — fill must equal the venue's own Router02 quote, both ways ──────

    function _v2RoundTripExact(
        string memory label,
        address pair,
        address v2Router,
        address tokenB,
        uint256 amountA,
        uint256 maxBelowBps
    ) internal {
        deal(WETH, user, amountA);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = tokenB;
        uint256 quoteFwd = IV2Router02(v2Router).getAmountsOut(amountA, path)[1];
        console2.log(string.concat("== ", label, " fwd"));
        uint256 spot1 = _spot(_v2(label, v2Adapter, pair), WETH, amountA);
        uint256 outB = _routerSwap(v2Adapter, WETH, tokenB, amountA, abi.encode(pair));
        assertEq(outB, quoteFwd, string.concat(label, ": fwd fill != Router02.getAmountsOut"));
        _assertBand(outB, spot1, maxBelowBps, string.concat(label, " fwd"));

        path[0] = tokenB;
        path[1] = WETH;
        uint256 quoteRev = IV2Router02(v2Router).getAmountsOut(outB, path)[1];
        console2.log(string.concat("== ", label, " rev"));
        uint256 back = _routerSwap(v2Adapter, tokenB, WETH, outB, abi.encode(pair));
        assertEq(back, quoteRev, string.concat(label, ": rev fill != Router02.getAmountsOut"));
        assertGt(back, (amountA * 9_900) / 10_000, string.concat(label, ": round trip kept < 99 %"));
    }

    /// The pair is thin (10.8 WETH): 0.2 WETH moved it 2.1 % (= 0.2 / 11.0 impact + 0.3 % fee, measured at block
    /// 514,750,000 — fill still == Router02). 0.05 WETH keeps impact + fee inside 1 %.
    function test_uniswapV2_WETH_USDC_equalsRouter() public {
        _v2RoundTripExact("Uniswap V2 WETH/USDC", UNI_V2_WETH_USDC, UNISWAP_V2_ROUTER, USDC, 0.05 ether, 100);
    }

    function test_sushiV2_WETH_USDCe_equalsRouter() public {
        _v2RoundTripExact("SushiSwap V2 WETH/USDC.e", SUSHI_V2_WETH_USDCE, SUSHI_V2_ROUTER, USDCE, 0.2 ether, 100);
    }

    // ── V4 (ChordV4Adapter) ──────────────────────────────────────────────────────────────────────

    function _ethUsdcKey() internal pure returns (PoolKey memory) {
        // poolId 0x864abca0…903a8 = keccak(abi.encode(key)) (native ETH currency0, fee 500, ts 10, no hooks; read
        // 2026-10-14: initialised, lpFee 500, protocolFee 125 pips each way)
        return PoolKey({currency0: address(0), currency1: USDC, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function test_uniswapV4_poolIds() public pure {
        assertEq(
            keccak256(abi.encode(_ethUsdcKey())),
            0x864abca0a6202dba5b8868772308da953ff125b0f95015adbf89aaf579e903a8,
            "ETH/USDC poolId"
        );
        assertEq(
            keccak256(abi.encode(_usdcUsdt0Key())),
            0xab05003a63d2f34ac7eec4670bca3319f0e3d2f62af5c2b9cbd69d03fd804fd2,
            "USDC/USDT0 poolId"
        );
    }

    /// Native currency0: the adapter unwraps WETH → settles ETH, and wraps the ETH it takes back.
    function test_uniswapV4_nativeETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v4("Uniswap V4 ETH/USDC 0.05% (native)", v4Adapter, _ethUsdcKey()), WETH, USDC, 0.5 ether, 100);
    }

    function _usdcUsdt0Key() internal pure returns (PoolKey memory) {
        // ERC20/ERC20 (sync → transfer → settle path), fee 8 pips, ts 1, no hooks
        return PoolKey({currency0: USDC, currency1: USDT0, fee: 8, tickSpacing: 1, hooks: address(0)});
    }

    function test_uniswapV4_USDC_USDT0() public {
        deal(USDC, user, 2_000e6);
        _roundTrip(_v4("Uniswap V4 USDC/USDT0 fee 8", v4Adapter, _usdcUsdt0Key()), USDC, USDT0, 2_000e6, 50);
    }

    // ── router native legs on aeWETH ─────────────────────────────────────────────────────────────

    /// ETH in (msg.value, tokenIn = WETH → router deposit()) and ETH out (tokenOut = address(0) → router
    /// withdraw() + call) through `adapter` / `extraData`.
    function _nativeRoundTrip(string memory label, address adapter, bytes memory extraData) internal {
        INullRouter.RouteStep memory buy = INullRouter.RouteStep({
            adapter: adapter, tokenIn: WETH, tokenOut: USDC, amountIn: 0.3 ether, extraData: extraData
        });
        vm.prank(user);
        uint256 usdc = router.swap{value: 0.3 ether}(WETH, USDC, 0.3 ether, 1, block.timestamp + 600, buy, address(0));
        assertGt(usdc, 0, "native-in gave nothing");

        INullRouter.RouteStep memory sell = INullRouter.RouteStep({
            adapter: adapter, tokenIn: USDC, tokenOut: WETH, amountIn: usdc, extraData: extraData
        });
        uint256 ethBefore = user.balance;
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), usdc);
        uint256 eth = router.swap(USDC, address(0), usdc, 1, block.timestamp + 600, sell, address(0));
        vm.stopPrank();
        assertEq(user.balance - ethBefore, eth, "native-out not delivered");
        assertGt(eth, 0.297 ether, "round trip lost more than 1%");
        assertEq(address(router).balance, 0, "router kept ETH");
        assertEq(address(adapter).balance, 0, "adapter kept ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router kept WETH");
        console2.log(string.concat(label, " native round trip: 0.3 ETH -> USDC"), usdc);
        console2.log("  -> wei", eth);
    }

    function test_router_nativeIn_nativeOut_uniswapV3() public {
        _nativeRoundTrip("Uniswap V3", v3Adapter, abi.encode(UNI_V3_WETH_USDC_500));
    }

    /// Native ETH both sides of the router AND native currency0 in the V4 pool: router wraps, adapter unwraps,
    /// PoolManager settles ETH; back: PoolManager pays ETH, adapter wraps, router unwraps.
    function test_router_nativeIn_nativeOut_uniswapV4() public {
        _nativeRoundTrip("Uniswap V4", v4Adapter, abi.encode(_ethUsdcKey()));
    }

    // ── Metric v1 follow-up (script/DeployMetricV1Adapter.s.sol, deployer nonce 14 right after the stack) ─

    function _metricQuote(address pool, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        // Metric's oracle answers an off-chain read only when tx.origin is zero (what the engine's eth_call sends).
        vm.prank(address(0), address(0));
        (, out) = IMetricV1QuoterA(METRIC_V1_QUOTER).quoteLiveExactInSingle(
            pool, METRIC_V1_SIMPLE_ROUTER, zeroForOne, uint128(amt), zeroForOne ? 0 : type(uint128).max
        );
    }

    function _deployMetric() internal returns (address metric) {
        address predicted = vm.computeCreateAddress(DEPLOYER, 14);
        metric = new DeployMetricV1AdapterScript().deployAs(DEPLOYER);
        assertEq(metric, predicted, "Metric v1 adapter not at deployer nonce 14");
        assertEq(metric, 0x4e48D8bEDB4A781493e6193776FDa37e57Ce07b1, "Metric v1 adapter predicted address");
        assertEq(vm.getNonce(DEPLOYER), 16, "create + addAdapter");
        assertTrue(stack.registry.isApproved(metric), "Metric v1 not approved");
    }

    /// Both legs through the ROUTER, each fill == Metric's own quoter at the same state (token0 = WETH, token1 = USDC).
    function test_metricV1_followUp_WETH_USDC_equalsQuoter() public {
        address metric = _deployMetric();
        _assertNotRouterGate(metric, abi.encode(METRIC_V1_WETH_USDC));

        deal(WETH, user, 0.5 ether);
        uint256 q1 = _metricQuote(METRIC_V1_WETH_USDC, true, 0.5 ether);
        console2.log("== Metric v1 WETH/USDC fwd");
        uint256 usdc = _routerSwap(metric, WETH, USDC, 0.5 ether, abi.encode(METRIC_V1_WETH_USDC));
        assertEq(usdc, q1, "fwd fill != quoter");

        uint256 q2 = _metricQuote(METRIC_V1_WETH_USDC, false, usdc);
        console2.log("== Metric v1 WETH/USDC rev");
        uint256 back = _routerSwap(metric, USDC, WETH, usdc, abi.encode(METRIC_V1_WETH_USDC));
        assertEq(back, q2, "rev fill != quoter");
        assertGt(back, 0.495 ether, "round trip kept < 99 %");
    }

    function test_metricV1_followUp_USDC_USDT0_equalsQuoter() public {
        address metric = _deployMetric();
        deal(USDC, user, 2_000e6);
        uint256 q1 = _metricQuote(METRIC_V1_USDC_USDT0, true, 2_000e6);
        console2.log("== Metric v1 USDC/USDT0 fwd");
        uint256 usdt = _routerSwap(metric, USDC, USDT0, 2_000e6, abi.encode(METRIC_V1_USDC_USDT0));
        assertEq(usdt, q1, "fwd fill != quoter");

        uint256 q2 = _metricQuote(METRIC_V1_USDC_USDT0, false, usdt);
        console2.log("== Metric v1 USDC/USDT0 rev");
        uint256 back = _routerSwap(metric, USDT0, USDC, usdt, abi.encode(METRIC_V1_USDC_USDT0));
        assertEq(back, q2, "rev fill != quoter");
        assertGt(back, 1_990e6, "round trip kept < 99.5 %");
    }
}
