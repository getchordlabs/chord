// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkSwapHelpers} from "./ForkSwapHelpers.sol";
import {DeployAvalancheScript} from "../../script/DeployAvalanche.s.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";
import {UniV3AnyForkAdapter} from "../../src/adapters/UniV3AnyForkAdapter.sol";

/// @title AvalancheForkTest — docs/avalanche-contracts-deploy.md §6
/// @notice Deploys the Avalanche (43114) stack with `DeployAvalancheScript` AS the real deployer EOA on a
///         fork, proves the proxies align with Monad/RH/Arc, then round-trips real deep pools through the
///         NullRouter on every pinned venue. Name ends in `ForkTest` ⇒ CI skips it. Run:
///           forge test --match-path 'test/fork/AvalancheForkTest.t.sol' --fork-url https://moltnode.ag/avalanche -vv
contract AvalancheForkTest is ForkSwapHelpers {
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address constant BTC_B = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address constant PNG = 0x60781C2586D68229fde47564546784ab3fACA982;
    address constant STATE_VIEW = 0xc3c9e198C735a4b97e3e683f391cCBDD60B69286;

    // Deep pools (GeckoTerminal reserve, 2026-09-30)
    address constant UNI_V3_WAVAX_USDC_500 = 0xfAe3f424a0a47706811521E3ee268f00cFb5c45E; // $2.5M
    address constant PHARAOH_WAVAX_USDC = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534; // $3.7M, ts 10, fee() 800 dynamic
    address constant PHARAOH_BTCB_WAVAX = 0x5cA009013F6B898D134b6798B336A4592f3B4aF2; // $3.9M, ts 5
    address constant PANGOLIN_V3_USDT_USDC = 0x1150403B19315615Aad1638d9dd86cd866b2f456; // $147k, fee() 30, created at 100
    address constant PANGOLIN_V3_PNG_WAVAX = 0xfc2bb1598deF8283ee36718f9ADC0A721FB2E722; // $52k, fee() 2000, created at 500
    address constant LB22_WAVAX_USDC_BS10 = 0x864d4e5Ee7318e97483DB7EB0912E09F161516EA; // $663k
    address constant LFJ_V1_WAVAX_USDC = 0xf4003F4efBE8691B60249E6afbD307aBE7758adb; // $460k
    address constant PANGOLIN_V2_PNG_WAVAX = 0xd7538cABBf8605BdE1f4901B47B8D42c61DE0367; // $292k
    address constant BLACKHOLE_WAVAX_USDC = 0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7; // custom-deployer Algebra pool

    address v3Adapter;
    address v2Adapter;
    address v4Adapter;
    address lbAdapter;

    function setUp() public {
        _forkIfNeeded(43114, "AVAX_RPC_URL", "https://moltnode.ag/avalanche");
        stateView = STATE_VIEW;
        wrapped = WAVAX;
        _deployStack(new DeployAvalancheScript());
        v3Adapter = stack.adapters[0];
        v2Adapter = stack.adapters[1];
        v4Adapter = stack.adapters[2];
        lbAdapter = stack.adapters[3];
    }

    // ── deployment shape ─────────────────────────────────────────────────────────────────────────

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
        assertEq(lbAdapter, 0x1f0C20f5fd9762bf913C511a3Db6d870AcA04c3A, "LB adapter (nonce 11)");
        assertEq(stack.registry.adapterCount(), 4, "registry holds exactly the four new adapters");
        assertEq(router.wmon(), WAVAX, "router wraps WAVAX");
        assertEq(stack.feeCollector.feeBpsFor(USDC), 0, "USDC zero-fee");
        assertEq(stack.feeCollector.feeBpsFor(PNG), 25, "unlisted token pays the default");
        // 3 impls/proxies x2 + 4 adapters + setFeeCollector + 4 addAdapter + fee batch = 16 txs
        assertEq(vm.getNonce(DEPLOYER), 16, "deployer nonce after the run");
    }

    function test_H1_everyAdapterRejectsDirectCalls() public {
        _assertNotRouterGate(v3Adapter, abi.encode(UNI_V3_WAVAX_USDC_500));
        _assertNotRouterGate(v2Adapter, abi.encode(LFJ_V1_WAVAX_USDC));
        _assertNotRouterGate(v4Adapter, abi.encode(_avaxUsdcKey()));
        _assertNotRouterGate(lbAdapter, abi.encode(uint256(10)));
    }

    // ── V3 family (UniV3AnyForkAdapter) ──────────────────────────────────────────────────────────

    function test_uniswapV3_WAVAX_USDC() public {
        deal(WAVAX, user, 20 ether);
        _roundTrip(_v3("Uniswap V3 WAVAX/USDC 0.05%", v3Adapter, UNI_V3_WAVAX_USDC_500), WAVAX, USDC, 20 ether, 100);
    }

    /// Pharaoh V3: tickSpacing-keyed registry (the AnyFork lane) + dynamic fee.
    function test_pharaohV3_WAVAX_USDC() public {
        deal(WAVAX, user, 20 ether);
        _roundTrip(_v3("Pharaoh V3 WAVAX/USDC ts10", v3Adapter, PHARAOH_WAVAX_USDC), WAVAX, USDC, 20 ether, 100);
    }

    function test_pharaohV3_WAVAX_BTCb() public {
        deal(WAVAX, user, 20 ether);
        _roundTrip(_v3("Pharaoh V3 BTC.b/WAVAX ts5", v3Adapter, PHARAOH_BTCB_WAVAX), WAVAX, BTC_B, 20 ether, 100);
    }

    /// Pangolin V3: live fee() (30) is NOT the creation key (100) — authenticated by the candidate tiers.
    function test_pangolinV3_USDC_USDt_dynamicFee() public {
        deal(USDC, user, 500e6);
        _roundTrip(_v3("Pangolin V3 USDt/USDC (fee 30, key 100)", v3Adapter, PANGOLIN_V3_USDT_USDC), USDC, USDT, 500e6, 100);
    }

    function test_pangolinV3_WAVAX_PNG_dynamicFee() public {
        deal(WAVAX, user, 5 ether);
        _roundTrip(_v3("Pangolin V3 PNG/WAVAX (fee 2000, key 500)", v3Adapter, PANGOLIN_V3_PNG_WAVAX), WAVAX, PNG, 5 ether, 250);
    }

    /// Not served, on purpose: Blackhole's custom-deployer Algebra pool is unknown to factory.poolByPair,
    /// so the adapter must refuse it (engine must not route Blackhole V3 to this adapter).
    function test_blackholeCustomPool_isRefused() public {
        deal(WAVAX, user, 1 ether);
        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WAVAX, tokenOut: USDC, amountIn: 1 ether,
            extraData: abi.encode(BLACKHOLE_WAVAX_USDC)
        });
        vm.startPrank(user);
        IERC20(WAVAX).approve(address(router), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, BLACKHOLE_WAVAX_USDC));
        router.swap(WAVAX, USDC, 1 ether, 1, block.timestamp + 600, step, address(0));
        vm.stopPrank();
    }

    // ── Liquidity Book v2.2 (LFJAdapter) ─────────────────────────────────────────────────────────

    function test_lfjLB22_WAVAX_USDC() public {
        deal(WAVAX, user, 20 ether);
        _roundTrip(_lb("LFJ LB v2.2 WAVAX/USDC bs10", lbAdapter, LB22_WAVAX_USDC_BS10, 10), WAVAX, USDC, 20 ether, 150);
    }

    // ── V2 (UniV2TaxSafeAdapter) ─────────────────────────────────────────────────────────────────

    function test_lfjV1_WAVAX_USDC() public {
        deal(WAVAX, user, 10 ether);
        _roundTrip(_v2("LFJ V1 WAVAX/USDC", v2Adapter, LFJ_V1_WAVAX_USDC), WAVAX, USDC, 10 ether, 100);
    }

    function test_pangolinV2_WAVAX_PNG() public {
        deal(WAVAX, user, 10 ether);
        _roundTrip(_v2("Pangolin V2 PNG/WAVAX", v2Adapter, PANGOLIN_V2_PNG_WAVAX), WAVAX, PNG, 10 ether, 150);
    }

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────

    function _avaxUsdcKey() internal pure returns (PoolKey memory) {
        // poolId 0x6874d3d2… (native AVAX currency0, fee 500, ts 10, no hooks)
        return PoolKey({currency0: address(0), currency1: USDC, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function test_uniswapV4_nativeAVAX_USDC() public {
        deal(WAVAX, user, 3 ether);
        _roundTrip(_v4("Uniswap V4 AVAX/USDC 0.05% (native)", v4Adapter, _avaxUsdcKey()), WAVAX, USDC, 3 ether, 150);
    }

    // ── router native legs on WAVAX ──────────────────────────────────────────────────────────────

    function test_router_nativeIn_nativeOut() public {
        INullRouter.RouteStep memory buy = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WAVAX, tokenOut: USDC, amountIn: 5 ether,
            extraData: abi.encode(UNI_V3_WAVAX_USDC_500)
        });
        vm.prank(user);
        uint256 usdc = router.swap{value: 5 ether}(WAVAX, USDC, 5 ether, 1, block.timestamp + 600, buy, address(0));
        assertGt(usdc, 0, "native-in gave nothing");

        INullRouter.RouteStep memory sell = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: USDC, tokenOut: WAVAX, amountIn: usdc,
            extraData: abi.encode(UNI_V3_WAVAX_USDC_500)
        });
        uint256 before = user.balance;
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), usdc);
        uint256 avax = router.swap(USDC, address(0), usdc, 1, block.timestamp + 600, sell, address(0));
        vm.stopPrank();
        assertApproxEqAbs(user.balance - before, avax, 1e15, "native-out not delivered");
        assertGt(avax, 4.95 ether, "round trip lost more than 1%");
        assertEq(address(router).balance, 0, "router kept AVAX");
        assertEq(IERC20(WAVAX).balanceOf(address(router)), 0, "router kept WAVAX");
        console2.log("native round trip: 5 AVAX ->", usdc, "USDC -> wei", avax);
    }
}
