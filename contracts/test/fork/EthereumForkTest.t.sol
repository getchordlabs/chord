// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ForkSwapHelpers} from "./ForkSwapHelpers.sol";
import {DeployEthereumScript} from "../../script/DeployEthereum.s.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";
import {UniV3AnyForkAdapter} from "../../src/adapters/UniV3AnyForkAdapter.sol";
import {UniV2TaxSafeAdapter} from "../../src/adapters/UniV2TaxSafeAdapter.sol";
import {UniswapV4Adapter} from "../../src/adapters/UniswapV4Adapter.sol";

interface IV2Router02E {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// @title EthereumForkTest — docs/ethereum-contracts-deploy.md §6 (board #279)
/// @notice Deploys the Ethereum mainnet (chain 1) stack with `DeployEthereumScript` AS the real deployer EOA on a fork,
///         proves the proxies align with every other chain and that each contract lands on Base's / Arbitrum's address
///         number, then round-trips real pools through the router on every venue the engine routes first: Uniswap V3,
///         PancakeSwap V3 (pool-direct, fallback callback), SushiSwap V3, Uniswap V2, SushiSwap V2, Uniswap V4 (native
///         ETH and ERC20 pools, with the protocol fee mainnet pools carry) and the router's native ETH legs. Metric v1 is
///         NOT in the set: its volatile pools answer FeedStalled to an off-chain read on chain 1 (runbook §0). USDT (no
///         return value on approve / transfer, approve only from zero) rides every family both ways. Name ends in `ForkTest` ⇒ CI skips it. Run (pin a block so reruns hit forge's RPC cache):
///           forge test --match-contract EthereumForkTest --fork-url "$ETH_RPC_URL" --fork-block-number <N> -vv
contract EthereumForkTest is ForkSwapHelpers {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA; // not on the zero-fee list
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SUSHI_V3_FACTORY = 0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F;
    address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant SUSHI_V2_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // factory() = Uniswap V2
    address constant SUSHI_V2_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // factory() = SushiSwap V2

    // Pools (factory.getPool / getPair read 2026-10-15; WETH held by the pool in brackets).
    address constant UNI_V3_WETH_USDC_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 9,725 WETH (token0 = USDC)
    address constant UNI_V3_WETH_USDT_3000 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36; // 26,757 WETH
    address constant PCS_V3_WETH_USDC_100 = 0x1445F32D1A74872bA41f3D8cF4022E9996120b31; // 119 WETH
    address constant PCS_V3_WETH_USDT_500 = 0x6CA298D2983aB03Aa1dA7679389D955A4eFEE15C; // 37 WETH
    address constant SUSHI_V3_WETH_USDC_3000 = 0x763d3b7296e7C9718AD5B058aC2692A19E5b3638; // 428 WETH (Sushi's deepest)
    address constant UNI_V2_WETH_USDC = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc; // 4,086 WETH
    address constant UNI_V2_WETH_USDT = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852; // 2,946 WETH
    address constant SUSHI_V2_WETH_USDC = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0; // 56 WETH
    address constant SUSHI_V2_WETH_USDT = 0x06da0fd433C1A5d7a4faa01111c044910A184553; // 126 WETH
    /// A V3-shaped pool of a factory nobody pinned (0x00a38533…, the tape's #3 V3-shaped factory, PoolCreated fee 120).
    address constant UNPINNED_V3_POOL = 0x779466861A963a1564061E868f228D65dd11F14a;

    address v3Adapter;
    address v2Adapter;
    address v4Adapter;

    function setUp() public {
        _forkIfNeeded(1, "ETH_RPC_URL", "https://ethereum-rpc.publicnode.com");
        stateView = STATE_VIEW;
        wrapped = WETH;
        _deployStack(new DeployEthereumScript());
        v3Adapter = stack.adapters[0];
        v2Adapter = stack.adapters[1];
        v4Adapter = stack.adapters[2];
    }

    // ── deployment shape ─────────────────────────────────────────────────────────────────────────

    /// Same proxies as every chain; same deployer + same nonces ⇒ every contract lands on Base's (and Arbitrum's)
    /// address NUMBER (docs/contracts-verification.md §Base / §Arbitrum). Bytecode differs where the constructor
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
        assertEq(stack.feeCollector.feeBpsFor(USDT), 0, "USDT");
        assertEq(stack.feeCollector.feeBpsFor(DAI), 0, "DAI");
        assertEq(stack.feeCollector.feeBpsFor(WETH), 0, "WETH (and native ETH out)");
        assertEq(stack.feeCollector.feeBpsFor(WBTC), 0, "WBTC");
        assertEq(stack.feeCollector.feeBpsFor(LINK), 5, "unlisted token pays the default");
    }

    function test_H1_everyAdapterRejectsDirectCalls() public {
        _assertNotRouterGate(v3Adapter, abi.encode(UNI_V3_WETH_USDC_500));
        _assertNotRouterGate(v2Adapter, abi.encode(UNI_V2_WETH_USDC));
        _assertNotRouterGate(v4Adapter, abi.encode(_ethUsdcKey()));
    }

    // ── V3 family (ChordV3Adapter) ───────────────────────────────────────────────────────────────

    function test_uniswapV3_WETH_USDC_500() public {
        deal(WETH, user, 1 ether);
        _roundTrip(_v3("Uniswap V3 WETH/USDC 0.05%", v3Adapter, UNI_V3_WETH_USDC_500), WETH, USDC, 1 ether, 100);
    }

    /// USDT out of the pool, then USDT paid INTO the pool from the callback (TransferLib, no return value).
    function test_uniswapV3_WETH_USDT_3000() public {
        deal(WETH, user, 1 ether);
        _roundTrip(_v3("Uniswap V3 WETH/USDT 0.3%", v3Adapter, UNI_V3_WETH_USDT_3000), WETH, USDT, 1 ether, 100);
    }

    /// PancakeSwap V3 calls back `pancakeV3SwapCallback` — served by the adapter's fallback; pool CREATE2'd by the
    /// PoolDeployer 0x41ff9AA7…, authenticated through factory.getPool.
    function test_pancakeV3_WETH_USDC_100() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("PancakeSwap V3 WETH/USDC 0.01%", v3Adapter, PCS_V3_WETH_USDC_100), WETH, USDC, 0.5 ether, 100);
    }

    function test_pancakeV3_WETH_USDT_500() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("PancakeSwap V3 WETH/USDT 0.05%", v3Adapter, PCS_V3_WETH_USDT_500), WETH, USDT, 0.5 ether, 100);
    }

    function test_sushiV3_WETH_USDC_3000() public {
        deal(WETH, user, 0.5 ether);
        _roundTrip(_v3("SushiSwap V3 WETH/USDC 0.3%", v3Adapter, SUSHI_V3_WETH_USDC_3000), WETH, USDC, 0.5 ether, 100);
    }

    /// A pool no pinned factory created is refused before any token moves.
    function test_v3_unpinnedFactoryPool_refused() public {
        deal(WETH, user, 0.1 ether);
        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: v3Adapter, tokenIn: WETH, tokenOut: USDC, amountIn: 0.1 ether, extraData: abi.encode(UNPINNED_V3_POOL)
        });
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, UNPINNED_V3_POOL));
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
        uint256 quoteFwd = IV2Router02E(v2Router).getAmountsOut(amountA, path)[1];
        console2.log(string.concat("== ", label, " fwd"));
        uint256 spot1 = _spot(_v2(label, v2Adapter, pair), WETH, amountA);
        uint256 outB = _routerSwap(v2Adapter, WETH, tokenB, amountA, abi.encode(pair));
        assertEq(outB, quoteFwd, string.concat(label, ": fwd fill != Router02.getAmountsOut"));
        _assertBand(outB, spot1, maxBelowBps, string.concat(label, " fwd"));

        path[0] = tokenB;
        path[1] = WETH;
        uint256 quoteRev = IV2Router02E(v2Router).getAmountsOut(outB, path)[1];
        console2.log(string.concat("== ", label, " rev"));
        uint256 back = _routerSwap(v2Adapter, tokenB, WETH, outB, abi.encode(pair));
        assertEq(back, quoteRev, string.concat(label, ": rev fill != Router02.getAmountsOut"));
        assertGt(back, (amountA * 9_900) / 10_000, string.concat(label, ": round trip kept < 99 %"));
    }

    function test_uniswapV2_WETH_USDC_equalsRouter() public {
        _v2RoundTripExact("Uniswap V2 WETH/USDC", UNI_V2_WETH_USDC, UNISWAP_V2_ROUTER, USDC, 1 ether, 100);
    }

    function test_uniswapV2_WETH_USDT_equalsRouter() public {
        _v2RoundTripExact("Uniswap V2 WETH/USDT", UNI_V2_WETH_USDT, UNISWAP_V2_ROUTER, USDT, 1 ether, 100);
    }

    /// 56 WETH in the pair: 0.1 WETH = ~0.18 % impact + 0.3 % fee per leg.
    function test_sushiV2_WETH_USDC_equalsRouter() public {
        _v2RoundTripExact("SushiSwap V2 WETH/USDC", SUSHI_V2_WETH_USDC, SUSHI_V2_ROUTER, USDC, 0.1 ether, 100);
    }

    function test_sushiV2_WETH_USDT_equalsRouter() public {
        _v2RoundTripExact("SushiSwap V2 WETH/USDT", SUSHI_V2_WETH_USDT, SUSHI_V2_ROUTER, USDT, 0.2 ether, 100);
    }

    // ── V4 (ChordV4Adapter) — mainnet pools carry a protocol fee on top of the LP fee ────────────

    function _ethUsdcKey() internal pure returns (PoolKey memory) {
        // poolId 0x21c67e77…82ca27 (native ETH currency0, fee 500, ts 10, no hooks; read 2026-10-15: protocolFee 0x07D07D)
        return PoolKey({currency0: address(0), currency1: USDC, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function _ethUsdtKey() internal pure returns (PoolKey memory) {
        // poolId 0x72331fcb…79ca73 (native ETH, fee 500, ts 10, no hooks; protocolFee 0x07D07D)
        return PoolKey({currency0: address(0), currency1: USDT, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function _usdcUsdtKey() internal pure returns (PoolKey memory) {
        // poolId 0x395f91b3…f713a5 — ERC20/ERC20 (sync → transfer → settle path), fee 8 pips, ts 1, protocolFee 0x002002
        return PoolKey({currency0: USDC, currency1: USDT, fee: 8, tickSpacing: 1, hooks: address(0)});
    }

    function test_uniswapV4_poolIds() public pure {
        assertEq(
            keccak256(abi.encode(_ethUsdcKey())),
            0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27,
            "ETH/USDC poolId"
        );
        assertEq(
            keccak256(abi.encode(_ethUsdtKey())),
            0x72331fcb696b0151904c03584b66dc8365bc63f8a144d89a773384e3a579ca73,
            "ETH/USDT poolId"
        );
        assertEq(
            keccak256(abi.encode(_usdcUsdtKey())),
            0x395f91b34aa34a477ce3bc6505639a821b286a62b1a164fc1887fa3a5ef713a5,
            "USDC/USDT poolId"
        );
    }

    /// Native currency0: the adapter unwraps WETH → settles ETH, and wraps the ETH it takes back.
    function test_uniswapV4_nativeETH_USDC() public {
        deal(WETH, user, 1 ether);
        _roundTrip(_v4("Uniswap V4 ETH/USDC 0.05% (native)", v4Adapter, _ethUsdcKey()), WETH, USDC, 1 ether, 100);
    }

    function test_uniswapV4_nativeETH_USDT() public {
        deal(WETH, user, 1 ether);
        _roundTrip(_v4("Uniswap V4 ETH/USDT 0.05% (native)", v4Adapter, _ethUsdtKey()), WETH, USDT, 1 ether, 100);
    }

    function test_uniswapV4_USDC_USDT() public {
        deal(USDC, user, 2_000e6);
        _roundTrip(_v4("Uniswap V4 USDC/USDT fee 8", v4Adapter, _usdcUsdtKey()), USDC, USDT, 2_000e6, 50);
    }

    // ── router native legs on WETH9 ──────────────────────────────────────────────────────────────

    /// ETH in (msg.value, tokenIn = WETH → router deposit()) and ETH out (tokenOut = address(0) → router
    /// withdraw() + call) through `adapter` / `extraData`. WETH9.withdraw forwards ETH with a 2,300-gas stipend —
    /// the router proxy's receive() must fit in it (the proxy + impl are warm by then).
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
        SafeERC20.forceApprove(IERC20(USDC), address(router), usdc);
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

    function test_router_nativeIn_nativeOut_uniswapV2() public {
        _nativeRoundTrip("Uniswap V2", v2Adapter, abi.encode(UNI_V2_WETH_USDC));
    }
}
