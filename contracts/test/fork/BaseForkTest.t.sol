// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkSwapHelpers} from "./ForkSwapHelpers.sol";
import {DeployBaseScript} from "../../script/DeployBase.s.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";
import {UniV2GenericAdapter} from "../../src/adapters/UniV2GenericAdapter.sol";

/// @title BaseForkTest — docs/base-contracts-deploy.md §6
/// @notice Deploys the Base (8453) stack with `DeployBaseScript` AS the real deployer EOA on a fork,
///         proves the proxies align with Monad/RH/Arc, then round-trips real deep pools through the
///         NullRouter on every pinned venue. Name ends in `ForkTest` ⇒ CI skips it
///         (`forge test --no-match-contract 'ForkTest$'`). Run:
///           forge test --match-path 'test/fork/BaseForkTest.t.sol' --fork-url https://moltnode.ag/base -vv
contract BaseForkTest is ForkSwapHelpers {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant TIBBIR = 0xA4A2E2ca3fBfE21aed83471D28b6f65A233C6e00; // Virtuals agent token, 1 %/1 % tax
    address constant ICP = 0x00f3C42833C3170159af4E92dbb451Fb3F708917;
    address constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address constant UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;

    // Deep pools (GeckoTerminal reserve, 2026-09-30) — one per venue, two for Uniswap V3 / V4.
    address constant UNI_V3_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // $9.8M
    address constant UNI_V3_CBBTC_WETH_500 = 0x7AeA2E8A3843516afa07293a10Ac8E49906dabD1; // $13.5M
    address constant SS3_WETH_USDC_TS50 = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A; // $10.8M
    address constant SS1_WETH_USDC_TS100 = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59; // $7.9M
    address constant SS2_ICP_WETH = 0xBe762d548f8CA86A78E9Da6e3DdC87F91457e398; // $0.74M (#2 pool of SS#2)
    address constant PCS_V3_WETH_USDC_100 = 0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38; // $5.0M
    address constant QS_V4_WETH_USDC = 0x5a9Ad2BB92B0B3E5C571FDD5125114E04E02be1a; // $0.2M (Algebra Integral)
    address constant HYDREX_WETH_CBBTC = 0x3f9b863EF4B295d6Ba370215bcCa3785FCC44f44; // $1.25M (Algebra Integral)
    address constant UNI_V2_WETH_USDC = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C; // ~$1.3M
    address constant UNI_V2_VIRTUAL_TIBBIR = 0x0c3b466104545efa096b8f944c1e524E1d0D4888; // $3.9M, #1 V2 pair

    address v3Adapter;
    address v2Adapter;
    address v4Adapter;

    function setUp() public {
        _forkIfNeeded(8453, "BASE_RPC_URL", "https://moltnode.ag/base");
        stateView = STATE_VIEW;
        wrapped = WETH;
        _deployStack(new DeployBaseScript());
        v3Adapter = stack.adapters[0];
        v2Adapter = stack.adapters[1];
        v4Adapter = stack.adapters[2];
    }

    // ── deployment shape ─────────────────────────────────────────────────────────────────────────

    /// The whole point of the nonce map: same proxies as Monad / RH / Arc, and — because the deployer
    /// and nonces are identical — the same impl addresses as Arc too. Adapter addresses are predicted
    /// here so the runbook can list them before anything is broadcast.
    function test_addresses_alignWithMonadRhArc() public view {
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
        assertEq(stack.feeCollector.feeBpsFor(USDC), 0, "USDC zero-fee");
        assertEq(stack.feeCollector.feeBpsFor(TIBBIR), 25, "unlisted token pays the default");
        // 3 impls/proxies ×2 + 3 adapters + setFeeCollector + 3 addAdapter + fee batch = 14 txs
        assertEq(vm.getNonce(DEPLOYER), 14, "deployer nonce after the run");
    }

    function test_H1_everyAdapterRejectsDirectCalls() public {
        _assertNotRouterGate(v3Adapter, abi.encode(UNI_V3_WETH_USDC_500));
        _assertNotRouterGate(v2Adapter, abi.encode(UNI_V2_WETH_USDC));
        _assertNotRouterGate(v4Adapter, abi.encode(_ethUsdcKey()));
    }

    // ── V3 family (UniV3AnyForkAdapter) ──────────────────────────────────────────────────────────

    function test_uniswapV3_WETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("Uniswap V3 WETH/USDC 0.05%", v3Adapter, UNI_V3_WETH_USDC_500), WETH, USDC, 0.5 ether, 100);
    }

    function test_uniswapV3_WETH_cbBTC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("Uniswap V3 cbBTC/WETH 0.05%", v3Adapter, UNI_V3_CBBTC_WETH_500), WETH, CBBTC, 0.5 ether, 100);
    }

    /// Slipstream: tickSpacing-keyed registry — the lane UniV3GenericAdapter does not have.
    function test_slipstream3_WETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("Slipstream#3 WETH/USDC ts50", v3Adapter, SS3_WETH_USDC_TS50), WETH, USDC, 0.5 ether, 100);
    }

    function test_slipstream1_WETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("Slipstream#1 WETH/USDC ts100", v3Adapter, SS1_WETH_USDC_TS100), WETH, USDC, 0.5 ether, 100);
    }

    function test_slipstream2_WETH_ICP() public {
        deal(WETH, user, 0.1 ether);
        _roundTrip(_v3("Slipstream#2 ICP/WETH", v3Adapter, SS2_ICP_WETH), WETH, ICP, 0.1 ether, 200);
    }

    /// PancakeSwap V3 calls back `pancakeV3SwapCallback` — served by the adapter's fallback.
    function test_pancakeV3_WETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("PancakeSwap V3 WETH/USDC 0.01%", v3Adapter, PCS_V3_WETH_USDC_100), WETH, USDC, 0.5 ether, 100);
    }

    /// Algebra Integral: `poolByPair` registry (pass 1) + `algebraSwapCallback` via fallback.
    function test_quickswapV4_WETH_USDC() public {
        deal(WETH, user, 0.1 ether);
        _roundTrip(_v3("QuickSwap V4 WETH/USDC", v3Adapter, QS_V4_WETH_USDC), WETH, USDC, 0.1 ether, 200);
    }

    function test_hydrex_WETH_cbBTC() public {
        deal(WETH, user, 0.2 ether);
        _roundTrip(_v3("Hydrex WETH/cbBTC", v3Adapter, HYDREX_WETH_CBBTC), WETH, CBBTC, 0.2 ether, 200);
    }

    // ── V2 (UniV2TaxSafeAdapter) ─────────────────────────────────────────────────────────────────

    function test_uniswapV2_WETH_USDC() public {
        deal(WETH, user, 0.2 ether);
        _roundTrip(_v2("Uniswap V2 WETH/USDC", v2Adapter, UNI_V2_WETH_USDC), WETH, USDC, 0.2 ether, 100);
    }

    /// Base's #1 V2 pair. Band = 0.3 % pool + 1 % transfer tax + 25 bps router default fee on the
    /// output + impact.
    function test_uniswapV2_taxed_VIRTUAL_TIBBIR() public {
        deal(VIRTUAL, user, 500 ether);
        _roundTrip(_v2("Uniswap V2 VIRTUAL/TIBBIR (1% tax)", v2Adapter, UNI_V2_VIRTUAL_TIBBIR), VIRTUAL, TIBBIR, 500 ether, 250);
    }

    /// Negative control for the adapter choice: the generic V2 adapter (priced off amountIn) cannot
    /// sell a taxed token — the pair receives amountIn×(1−tax) and its K check reverts.
    function test_uniswapV2_taxedSell_revertsOnGenericAdapter() public {
        address[] memory f = new address[](1);
        f[0] = UNISWAP_V2_FACTORY;
        address generic = address(new UniV2GenericAdapter(address(router), f));
        vm.prank(DEPLOYER);
        stack.registry.addAdapter(generic);

        deal(VIRTUAL, user, 500 ether);
        uint256 tib = _routerSwap(v2Adapter, VIRTUAL, TIBBIR, 500 ether, abi.encode(UNI_V2_VIRTUAL_TIBBIR));

        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: generic, tokenIn: TIBBIR, tokenOut: VIRTUAL, amountIn: tib,
            extraData: abi.encode(UNI_V2_VIRTUAL_TIBBIR)
        });
        vm.startPrank(user);
        IERC20(TIBBIR).approve(address(router), tib);
        vm.expectRevert(bytes("UniswapV2: K"));
        router.swap(TIBBIR, VIRTUAL, tib, 1, block.timestamp + 600, step, address(0));
        vm.stopPrank();
    }

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────

    function _ethUsdcKey() internal pure returns (PoolKey memory) {
        // poolId 0x96d4b53a… (native ETH currency0, fee 500, ts 10, no hooks)
        return PoolKey({currency0: address(0), currency1: USDC, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    /// Native currency0: the adapter unwraps WETH → settles ETH, and wraps the ETH it takes back.
    function test_uniswapV4_nativeETH_USDC() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v4("Uniswap V4 ETH/USDC 0.05% (native)", v4Adapter, _ethUsdcKey()), WETH, USDC, 0.5 ether, 100);
    }

    function test_uniswapV4_USDC_cbBTC() public {
        // poolId 0x12d76c5c… (ERC20/ERC20, fee 500, ts 10, no hooks)
        PoolKey memory key = PoolKey({currency0: USDC, currency1: CBBTC, fee: 500, tickSpacing: 10, hooks: address(0)});
        deal(USDC, user, 2_000e6);
        _roundTrip(_v4("Uniswap V4 USDC/cbBTC 0.05%", v4Adapter, key), USDC, CBBTC, 2_000e6, 100);
    }

    // ── router native legs on Base's WETH9 predeploy ─────────────────────────────────────────────

    /// ETH in (msg.value, tokenIn = WETH → router deposit()) and ETH out (tokenOut = address(0) →
    /// router withdraw() + call) on the deepest venue.
    function test_router_nativeIn_nativeOut() public {
        INullRouter.RouteStep memory buy = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WETH, tokenOut: USDC, amountIn: 0.3 ether,
            extraData: abi.encode(UNI_V3_WETH_USDC_500)
        });
        vm.prank(user);
        uint256 usdc = router.swap{value: 0.3 ether}(WETH, USDC, 0.3 ether, 1, block.timestamp + 600, buy, address(0));
        assertGt(usdc, 0, "native-in gave nothing");

        INullRouter.RouteStep memory sell = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: USDC, tokenOut: WETH, amountIn: usdc,
            extraData: abi.encode(UNI_V3_WETH_USDC_500)
        });
        uint256 ethBefore = user.balance;
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), usdc);
        uint256 eth = router.swap(USDC, address(0), usdc, 1, block.timestamp + 600, sell, address(0));
        vm.stopPrank();
        // Forge bills the pranked caller the OP-stack L1 data fee (~1e10 wei per call on this fork), so
        // the balance delta is `eth` minus that; 1e13 wei (~$0.00003) is the tolerance.
        assertApproxEqAbs(user.balance - ethBefore, eth, 1e13, "native-out not delivered");
        assertGt(eth, 0.297 ether, "round trip lost more than 1%");
        assertEq(address(router).balance, 0, "router kept ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router kept WETH");
        console2.log("native round trip: 0.3 ETH ->", usdc, "USDC -> wei", eth);
    }
}
