// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NullRouter} from "../../src/NullRouter.sol";
import {INullRouter} from "../../src/interfaces/INullRouter.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {PoolKey} from "../../src/adapters/UniswapV4Adapter.sol";
import {AlignedStackDeploy} from "../../script/lib/AlignedStackDeploy.sol";

interface IUniV2PairView {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IV3PoolView {
    function token0() external view returns (address);
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
}

/// @title ForkSwapHelpers
/// @notice Shared plumbing for the `<Chain>ForkTest` suites (docs/multichain-plan.md §3 M3): deploy the
///         chain's stack with the REAL deploy script (as the real deployer EOA, no key — `deployAs`),
///         then push real swaps through the NullRouter proxy and check each fill against the pool's own
///         pre-swap spot price. Abstract + no `test*` functions, so it never runs on its own.
/// @dev Every swap goes USER → NullRouter.swap → adapter → pool, i.e. the production path including
///      registry approval, the H1 `onlyRouter` gate, M1 measured output, fee settlement and dust sweep.
abstract contract ForkSwapHelpers is Test {
    enum Kind {
        V3, // Uniswap V3 / Slipstream / PancakeSwap V3 / Algebra — spot from slot0 / globalState
        V2, // constant product — spot from reserves
        V4, // Uniswap V4 PoolManager — spot from StateView
        LB // Liquidity Book — spot supplied by the chain test (active bin price)
    }

    struct Venue {
        string label;
        address adapter;
        Kind kind;
        address pool; // V2/V3/LB pool address (unused for V4)
        PoolKey key; // V4 only
        bytes extraData;
    }

    AlignedStackDeploy.Stack internal stack;
    NullRouter internal router;
    address internal user = makeAddr("fork-user");
    address internal stateView; // V4 StateView of the chain (set by the chain test)
    address internal wrapped; // chain wrapped native (set by the chain test)

    // deployer EOA every chain's proxies are aligned to (nonce 0 on 8453 / 43114 / 56, 2026-09-30)
    address internal constant DEPLOYER = 0x0f1171209dAD379AF0E486f2c77D275D6E0a4f79;

    function _forkIfNeeded(uint256 chainId, string memory envKey, string memory fallbackUrl) internal {
        if (block.chainid != chainId) {
            vm.createSelectFork(vm.envOr(envKey, fallbackUrl));
        }
        require(block.chainid == chainId, "fork is not on the expected chain");
    }

    function _deployStack(AlignedStackDeploy script) internal {
        // Forge charges a pranked caller for gas on OP-stack forks (Base: the L1 data fee, ~1e10 wei per
        // call, measured) and a pranked account with 0 native reverts before executing. Fund both
        // accounts this suite pranks. Done AFTER the deploy check-in below would not matter for
        // alignment (a balance does not touch the nonce), but keep it first so nothing depends on order.
        vm.deal(user, 10 ether);
        uint256 g = gasleft();
        stack = script.deployAs(DEPLOYER, DEPLOYER);
        console2.log("deploy gas (whole stack, in-test metering):", g - gasleft());
        router = stack.router;
        vm.deal(DEPLOYER, 1 ether); // for vm.prank(DEPLOYER) owner calls in tests (after the deploy)
    }

    // ── venues ───────────────────────────────────────────────────────────────────────────────────

    function _v3(string memory label, address adapter, address pool) internal pure returns (Venue memory v) {
        v.label = label;
        v.adapter = adapter;
        v.kind = Kind.V3;
        v.pool = pool;
        v.extraData = abi.encode(pool);
    }

    function _v2(string memory label, address adapter, address pair) internal pure returns (Venue memory v) {
        v.label = label;
        v.adapter = adapter;
        v.kind = Kind.V2;
        v.pool = pair;
        v.extraData = abi.encode(pair);
    }

    function _v4(string memory label, address adapter, PoolKey memory key) internal pure returns (Venue memory v) {
        v.label = label;
        v.adapter = adapter;
        v.kind = Kind.V4;
        v.key = key;
        v.extraData = abi.encode(key);
    }

    // ── swaps ────────────────────────────────────────────────────────────────────────────────────

    /// @dev One router.swap from `user`, who must already hold `amountIn` of `tokenIn`.
    function _routerSwap(address adapter, address tokenIn, address tokenOut, uint256 amountIn, bytes memory extraData)
        internal
        returns (uint256 out)
    {
        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: adapter, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, extraData: extraData
        });
        vm.startPrank(user);
        IERC20(tokenIn).approve(address(router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(user);
        uint256 g = gasleft();
        out = router.swap(tokenIn, tokenOut, amountIn, 1, block.timestamp + 600, step, address(0));
        uint256 used = g - gasleft();
        vm.stopPrank();

        assertGt(out, 0, "no output");
        assertEq(IERC20(tokenOut).balanceOf(user) - before, out, "user credited != returned");
        // Router and adapter must end flat (dust sweep + push model).
        assertEq(IERC20(tokenIn).balanceOf(address(router)), 0, "router kept tokenIn");
        assertEq(IERC20(tokenOut).balanceOf(address(router)), 0, "router kept tokenOut");
        assertEq(IERC20(tokenIn).balanceOf(adapter), 0, "adapter kept tokenIn");
        assertEq(IERC20(tokenOut).balanceOf(adapter), 0, "adapter kept tokenOut");
        console2.log("  gas", used);
        console2.log("  in ", amountIn);
        console2.log("  out", out);
    }

    /// @dev Pre-swap marginal price → expected output for amountIn before pool fee / impact.
    function _spot(Venue memory v, address tokenIn, uint256 amountIn) internal view virtual returns (uint256) {
        if (v.kind == Kind.V3) {
            return _spotFromSqrt(_v3Sqrt(v.pool), tokenIn == IV3PoolView(v.pool).token0(), amountIn);
        }
        if (v.kind == Kind.V2) {
            (uint112 r0, uint112 r1,) = IUniV2PairView(v.pool).getReserves();
            return tokenIn == IUniV2PairView(v.pool).token0()
                ? Math.mulDiv(amountIn, r1, r0)
                : Math.mulDiv(amountIn, r0, r1);
        }
        if (v.kind == Kind.V4) {
            (uint160 sqrtP,,,) = IStateView(stateView).getSlot0(keccak256(abi.encode(v.key)));
            bool zeroForOne = v.key.currency0 == tokenIn || (v.key.currency0 == address(0) && tokenIn == wrapped);
            return _spotFromSqrt(sqrtP, zeroForOne, amountIn);
        }
        revert("spot: override for this kind");
    }

    /// @dev V3 / Slipstream / PancakeSwap V3 (`slot0()`) and Algebra (`globalState()`) both put the
    ///      sqrt price in the first returned word.
    function _v3Sqrt(address pool) internal view returns (uint160 sqrtP) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || ret.length < 32) {
            (ok, ret) = pool.staticcall(abi.encodeWithSignature("globalState()"));
        }
        require(ok && ret.length >= 32, "no slot0/globalState");
        sqrtP = uint160(abi.decode(ret, (uint256)));
    }

    function _spotFromSqrt(uint160 sqrtP, bool zeroForOne, uint256 amountIn) internal pure returns (uint256) {
        uint256 q96 = 1 << 96;
        return zeroForOne
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, q96), sqrtP, q96)
            : Math.mulDiv(Math.mulDiv(amountIn, q96, sqrtP), q96, sqrtP);
    }

    /// @dev `out` must sit in [spot·(1 − maxBelowBps), spot·(1 + 30 bps)]. An exact-input fill cannot beat
    ///      the pre-swap marginal price, so the upper bound is rounding slack only; the lower bound covers
    ///      pool fee + price impact (+ transfer tax / router fee where a test says so).
    function _assertBand(uint256 out, uint256 spot, uint256 maxBelowBps, string memory label) internal pure {
        assertGe(out, (spot * (10_000 - maxBelowBps)) / 10_000, string.concat(label, ": below spot band"));
        assertLe(out, (spot * 10_030) / 10_000, string.concat(label, ": above spot"));
    }

    /// @dev tokenA → tokenB → tokenA through the SAME venue, each leg checked against the pool spot read
    ///      immediately before it. `user` must hold `amountA` of tokenA.
    function _roundTrip(Venue memory v, address tokenA, address tokenB, uint256 amountA, uint256 maxBelowBps)
        internal
        returns (uint256 outB, uint256 backA)
    {
        console2.log(string.concat("== ", v.label, " fwd"));
        uint256 spot1 = _spot(v, tokenA, amountA);
        outB = _routerSwap(v.adapter, tokenA, tokenB, amountA, v.extraData);
        _assertBand(outB, spot1, maxBelowBps, string.concat(v.label, " fwd"));

        console2.log(string.concat("== ", v.label, " rev"));
        uint256 spot2 = _spot(v, tokenB, outB);
        backA = _routerSwap(v.adapter, tokenB, tokenA, outB, v.extraData);
        _assertBand(backA, spot2, maxBelowBps, string.concat(v.label, " rev"));
    }

    /// @dev H1: a direct call from anything but the NullRouter proxy reverts NotRouter (0x91655201).
    function _assertNotRouterGate(address adapter, bytes memory extraData) internal {
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        IAdapter(adapter).swap(address(1), address(2), 1e6, address(this), extraData);
    }
}
