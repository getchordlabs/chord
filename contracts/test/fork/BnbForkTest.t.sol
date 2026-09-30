// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkSwapHelpers} from "./ForkSwapHelpers.sol";
import {DeployBnbScript} from "../../script/DeployBnb.s.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";

interface IPancakeRouterView {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// @title BnbForkTest — docs/bnb-contracts-deploy.md §6
/// @notice Deploys the BNB Chain (56) stack with `DeployBnbScript` AS the real deployer EOA on a fork, proves
///         the proxies align with Monad/RH/Arc, then round-trips real pools through the NullRouter on every
///         pinned venue. Name ends in `ForkTest` ⇒ CI skips it.
///         ⚠️ The gateway alternates two backends and one answers `not supported` for ANY historical state, which
///         forge does not retry — run it through a retrying proxy (docs/bnb-contracts-deploy.md §6):
///           forge test --match-path 'test/fork/BnbForkTest.t.sol' --fork-url http://127.0.0.1:18654 -vv
contract BnbForkTest is ForkSwapHelpers {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // 18 dec
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // 18 dec
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant RADR = 0xF08D1886E2A69dfaBd22a45Eed8e1407B338B97e; // taxed (recon §5.6)
    address constant WIRED = 0x55DB4b1f497b1D7Aa93354701883eFC758367777; // taxed Flap-graduated token
    address constant STATE_VIEW = 0xd13Dd3D6E93f276FAfc9Db9E6BB47C1180aeE0c4;
    address constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // Pools (GeckoTerminal reserve / on-chain balance, 2026-09-30)
    address constant PCS_V3_USDT_WBNB_100 = 0x172fcD41E0913e95784454622d1c3724f546f849; // $12.6M, busiest pool on BNB
    address constant PCS_V3_USDT_BTCB_500 = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4; // $22M
    address constant UNI_V3_USDT_WBNB_500 = 0x6fe9E9de56356F7eDBfcBB29FAB7cd69471a4869; // $4.7M
    address constant TOPAZ_USDT_WBNB = 0x767F1F4bF9E5E40F3D865c172c9bD0AE216e65B4; // ~$44k, ts 50
    address constant THENA_V3_USDT_WBNB = 0x9EA0f51Fd2133d995Cf00229bc523737415ad318; // ~$44k, Algebra Integral
    address constant PCS_V2_USDT_WBNB = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE; // $78.8M
    address constant PCS_V2_RADR_WBNB = 0x95084e204BCDF9110f2877Ba53A14B9Cf016c061; // 4,020 WBNB side
    address constant PCS_V2_WIRED_WBNB = 0x380462504f0EB4Eb9955E7dB3530559a7A3B0bEb; // 84.7 WBNB side

    address v3Adapter;
    address v2Adapter;
    address v4Adapter;

    function setUp() public {
        _forkIfNeeded(56, "BNB_RPC_URL", "http://127.0.0.1:18654");
        stateView = STATE_VIEW;
        wrapped = WBNB;
        _deployStack(new DeployBnbScript());
        v3Adapter = stack.adapters[0];
        v2Adapter = stack.adapters[1];
        v4Adapter = stack.adapters[2];
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
        assertEq(stack.registry.adapterCount(), 3, "registry holds exactly the three new adapters");
        assertEq(router.wmon(), WBNB, "router wraps WBNB");
        assertEq(stack.feeCollector.feeBpsFor(USDT), 0, "USDT zero-fee");
        assertEq(stack.feeCollector.feeBpsFor(RADR), 25, "unlisted token pays the default");
        assertEq(vm.getNonce(DEPLOYER), 14, "deployer nonce after the run");
    }

    function test_H1_everyAdapterRejectsDirectCalls() public {
        _assertNotRouterGate(v3Adapter, abi.encode(PCS_V3_USDT_WBNB_100));
        _assertNotRouterGate(v2Adapter, abi.encode(PCS_V2_USDT_WBNB));
        _assertNotRouterGate(v4Adapter, abi.encode(_bnbUsdtKey()));
    }

    // ── V3 family (UniV3AnyForkAdapter) ──────────────────────────────────────────────────────────

    /// PancakeSwap V3 calls back `pancakeV3SwapCallback` — served by the adapter's fallback.
    function test_pancakeV3_WBNB_USDT() public {
        deal(WBNB, user, 2 ether);
        _roundTrip(_v3("PancakeSwap V3 USDT/WBNB 0.01%", v3Adapter, PCS_V3_USDT_WBNB_100), WBNB, USDT, 2 ether, 100);
    }

    function test_pancakeV3_USDT_BTCB() public {
        deal(USDT, user, 2_000 ether);
        _roundTrip(_v3("PancakeSwap V3 USDT/BTCB 0.05%", v3Adapter, PCS_V3_USDT_BTCB_500), USDT, BTCB, 2_000 ether, 100);
    }

    function test_uniswapV3_WBNB_USDT() public {
        deal(WBNB, user, 2 ether);
        _roundTrip(_v3("Uniswap V3 USDT/WBNB 0.05%", v3Adapter, UNI_V3_USDT_WBNB_500), WBNB, USDT, 2 ether, 100);
    }

    /// Topaz: tickSpacing-keyed registry (the AnyFork lane) + dynamic fee.
    function test_topaz_WBNB_USDT() public {
        deal(WBNB, user, 0.2 ether);
        _roundTrip(_v3("Topaz USDT/WBNB ts50", v3Adapter, TOPAZ_USDT_WBNB), WBNB, USDT, 0.2 ether, 200);
    }

    /// THENA V3 (Algebra Integral): poolByPair (pass 1) + algebraSwapCallback via fallback.
    function test_thenaV3_WBNB_USDT() public {
        deal(WBNB, user, 0.2 ether);
        _roundTrip(_v3("THENA V3 USDT/WBNB", v3Adapter, THENA_V3_USDT_WBNB), WBNB, USDT, 0.2 ether, 200);
    }

    // ── V2 (UniV2FeeTaxSafeAdapter @ 25 bps) ─────────────────────────────────────────────────────

    /// The fee parameter is right iff the fill equals PancakeRouter.getAmountsOut for the same input.
    function test_pancakeV2_matchesPancakeRouterQuote_bothWays() public {
        deal(WBNB, user, 2 ether);
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;
        uint256 quoted = IPancakeRouterView(PANCAKE_V2_ROUTER).getAmountsOut(2 ether, path)[1];
        uint256 out = _routerSwap(v2Adapter, WBNB, USDT, 2 ether, abi.encode(PCS_V2_USDT_WBNB));
        assertEq(out, quoted, "fill == PancakeRouter.getAmountsOut (0.25 % fee)");

        path[0] = USDT;
        path[1] = WBNB;
        uint256 quotedBack = IPancakeRouterView(PANCAKE_V2_ROUTER).getAmountsOut(out, path)[1];
        uint256 back = _routerSwap(v2Adapter, USDT, WBNB, out, abi.encode(PCS_V2_USDT_WBNB));
        assertEq(back, quotedBack, "reverse fill == PancakeRouter.getAmountsOut");
        console2.log("PCS V2 2 WBNB ->", out, "USDT -> wei", back);
    }

    function test_pancakeV2_WBNB_USDT_band() public {
        deal(WBNB, user, 2 ether);
        _roundTrip(_v2("PancakeSwap V2 USDT/WBNB", v2Adapter, PCS_V2_USDT_WBNB), WBNB, USDT, 2 ether, 100);
    }

    /// Taxed tokens on PancakeSwap V2 (the reason for the TaxSafe family). Band covers pool 0.25 % + the
    /// token's transfer tax on each leg + the 25 bps router default fee on the token leg + impact.
    function test_pancakeV2_taxed_WBNB_RADR() public {
        deal(WBNB, user, 1 ether);
        _roundTrip(_v2("PancakeSwap V2 RADR/WBNB (taxed)", v2Adapter, PCS_V2_RADR_WBNB), WBNB, RADR, 1 ether, 1500);
    }

    function test_pancakeV2_taxed_WBNB_WIRED() public {
        deal(WBNB, user, 0.2 ether);
        _roundTrip(_v2("PancakeSwap V2 WIRED/WBNB (taxed)", v2Adapter, PCS_V2_WIRED_WBNB), WBNB, WIRED, 0.2 ether, 1500);
    }

    // ── V4 (UniswapV4Adapter) ────────────────────────────────────────────────────────────────────

    function _bnbUsdtKey() internal pure returns (PoolKey memory) {
        // poolId 0xa77d89e4… (native BNB currency0, fee 500, ts 10, no hooks; liquidity 1.56e23)
        return PoolKey({currency0: address(0), currency1: USDT, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function test_uniswapV4_nativeBNB_USDT() public {
        deal(WBNB, user, 1 ether);
        _roundTrip(_v4("Uniswap V4 BNB/USDT 0.05% (native)", v4Adapter, _bnbUsdtKey()), WBNB, USDT, 1 ether, 100);
    }

    function test_uniswapV4_USDT_USDC() public {
        // poolId 0x628ea54a… — PositionManager.poolKeys says (USDT, USDC, fee 2, ts 1, no hooks)
        PoolKey memory key = PoolKey({currency0: USDT, currency1: USDC, fee: 2, tickSpacing: 1, hooks: address(0)});
        deal(USDT, user, 1_000 ether);
        _roundTrip(_v4("Uniswap V4 USDT/USDC fee 2", v4Adapter, key), USDT, USDC, 1_000 ether, 50);
    }

    // ── router native legs on WBNB ───────────────────────────────────────────────────────────────

    function test_router_nativeIn_nativeOut() public {
        INullRouter.RouteStep memory buy = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WBNB, tokenOut: USDT, amountIn: 1 ether,
            extraData: abi.encode(PCS_V3_USDT_WBNB_100)
        });
        vm.prank(user);
        uint256 usdt = router.swap{value: 1 ether}(WBNB, USDT, 1 ether, 1, block.timestamp + 600, buy, address(0));
        assertGt(usdt, 0, "native-in gave nothing");

        INullRouter.RouteStep memory sell = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: USDT, tokenOut: WBNB, amountIn: usdt,
            extraData: abi.encode(PCS_V3_USDT_WBNB_100)
        });
        uint256 before = user.balance;
        vm.startPrank(user);
        IERC20(USDT).approve(address(router), usdt);
        uint256 bnb = router.swap(USDT, address(0), usdt, 1, block.timestamp + 600, sell, address(0));
        vm.stopPrank();
        assertApproxEqAbs(user.balance - before, bnb, 1e15, "native-out not delivered");
        assertGt(bnb, 0.99 ether, "round trip lost more than 1%");
        assertEq(address(router).balance, 0, "router kept BNB");
        assertEq(IERC20(WBNB).balanceOf(address(router)), 0, "router kept WBNB");
        console2.log("native round trip: 1 BNB ->", usdt, "USDT -> wei", bnb);
    }
}
