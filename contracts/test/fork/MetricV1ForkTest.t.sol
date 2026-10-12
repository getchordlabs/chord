// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MetricV1Adapter} from "../../src/adapters/MetricV1Adapter.sol";
import {ChordMetricV1Adapter} from "../../src/chord/ChordMetricV1Adapter.sol";

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IMetricV1Quoter {
    function quoteLiveExactInSingle(address pool, address sender, bool zeroForOne, uint128 amountIn, uint128 priceLimitX64)
        external
        returns (uint256 amountIn_, uint256 amountOut);
}

interface IMetricV1FactoryM {
    function isPool(address) external view returns (bool);
}

/// @notice Mainnet fork: the Chord Metric v1 adapter against Metric's real v1 deployment — the same factory, router
///         and quoter addresses on every chain. One test per chain's deepest pool (read on-chain 2026-10-11): sell
///         token0, then sell the proceeds back, each fill compared with Metric's own quoter at the same block.
///         Run one chain: METRIC_FORK_RPC=<url> forge test --match-contract MetricV1ForkTest -vv
///         (the test for another chain's pool skips itself). Excluded from CI with the other *ForkTest suites.
contract MetricV1ForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a; // Chord router proxy, every chain
    address constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address constant SIMPLE_ROUTER = 0x02201E6f13c41506c7Bb635d7543F98826229aB7;
    address constant QUOTER = 0x803Dd787ef9734c34696877ca6F20194fBcBFbF8;
    address constant USER = address(0xB0B);

    ChordMetricV1Adapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("METRIC_FORK_RPC"));
        adapter = new ChordMetricV1Adapter(ROUTER, SIMPLE_ROUTER, FACTORY);
    }

    /// @dev Metric's oracle answers `price()` to a pool that is mid-swap (`pool.inSwap()`), or to an off-chain read
    ///      whose tx.origin is the zero address — which is what an eth_call without `from` is, and what the engine
    ///      sends. From any other origin the quoter reverts (seen on the first run of this test), so the quote is
    ///      asked the way the engine asks it.
    function _quote(address pool, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        vm.prank(address(0), address(0));
        (, out) = IMetricV1Quoter(QUOTER).quoteLiveExactInSingle(
            pool, SIMPLE_ROUTER, zeroForOne, uint128(amt), zeroForOne ? 0 : type(uint128).max
        );
    }

    function _swap(address pool, address tin, address tout, uint256 amt) internal returns (uint256 out) {
        uint256 before = IERC20M(tout).balanceOf(USER);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, USER, abi.encode(pool));
        assertEq(IERC20M(tout).balanceOf(USER) - before, out, "delivered != returned");
        assertEq(IERC20M(tin).balanceOf(address(adapter)), 0, "input left in the adapter");
        assertEq(IERC20M(tout).balanceOf(address(adapter)), 0, "output left in the adapter");
    }

    /// @dev Sell `amt0` of token0, then sell what came out back; both fills must equal the quoter's number.
    function _bothWays(address pool, address token0, address token1, uint256 amt0, uint256 keepBps) internal {
        assertTrue(IMetricV1FactoryM(FACTORY).isPool(pool), "not a factory pool");
        deal(token0, address(adapter), amt0);
        uint256 q = _quote(pool, true, amt0);
        uint256 out1 = _swap(pool, token0, token1, amt0);
        console2.log("sell token0 ->", out1, "quoter", q);
        assertEq(out1, q, "execution != quote (sell token0)");

        vm.prank(USER);
        IERC20M(token1).transfer(address(adapter), out1);
        uint256 q2 = _quote(pool, false, out1);
        uint256 back = _swap(pool, token1, token0, out1);
        console2.log("sell token1 ->", back, "quoter", q2);
        assertEq(back, q2, "execution != quote (sell token1)");
        assertGt(back, amt0 * keepBps / 10_000, "round trip kept too little");
    }

    /// Monad 143 — WMON / USDC 0xe6831acf… (2.5M WMON + 37.8k USDC on 2026-10-11).
    function test_monad_wmonUsdc_bothWays_equalsQuoter() public {
        if (block.chainid != 143) return;
        _bothWays(
            0xE6831ACF980c2dFC5aE993F06b198d872FDdf515,
            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A,
            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
            10_000 ether,
            9_900
        );
    }

    /// Robinhood Chain 4663 — WETH / USDG 0x584ac601… (58 WETH + 55k USDG).
    function test_robinhood_wethUsdg_bothWays_equalsQuoter() public {
        if (block.chainid != 4663) return;
        _bothWays(
            0x584AC6010b095BF99398Fae8203A3260a03d2b30,
            0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
            0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
            0.5 ether,
            9_900
        );
    }

    /// Base 8453 — WETH / USDC 0x258be4ea… (47 WETH + 93k USDC).
    function test_base_wethUsdc_bothWays_equalsQuoter() public {
        if (block.chainid != 8453) return;
        vm.deal(ROUTER, 1 ether); // OP-stack forks charge the pranked caller the L1 data fee
        _bothWays(
            0x258bE4EA05f674e0B26AA71dfC08E0c87c499Fb0,
            0x4200000000000000000000000000000000000006,
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            0.5 ether,
            9_900
        );
    }

    /// Avalanche 43114 — WAVAX / USDC 0xc2c98809… (4,444 AVAX + 75k USDC).
    function test_avalanche_wavaxUsdc_bothWays_equalsQuoter() public {
        if (block.chainid != 43114) return;
        _bothWays(
            0xc2c98809CD77759aE3570804C713A6cdd1d649B7,
            0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7,
            0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
            100 ether,
            9_900
        );
    }

    /// A contract the factory never created is refused before any approval is given — and before any token is
    ///      touched, so this runs on every chain's fork: the two token addresses are Monad's and hold no code elsewhere
    ///      (funding the adapter with `deal` made this test revert on the Avalanche fork, 2026-10-12).
    function test_impostorPool_refused() public {
        address fake = address(new FakeMetricPool());
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(MetricV1Adapter.NotMetricPool.selector, fake));
        adapter.swap(
            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A,
            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
            1 ether,
            USER,
            abi.encode(fake)
        );
    }
}

/// Answers `getImmutables()` like the Monad WMON / USDC pool; the factory has never heard of it.
contract FakeMetricPool {
    function getImmutables() external pure returns (address, address, address) {
        return (
            0x2a53833cc95548cf52c7b159110e22D3a9018f32,
            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A,
            0x754704Bc059F8C67012fEd69BC8A327a5aafb603
        );
    }
}
