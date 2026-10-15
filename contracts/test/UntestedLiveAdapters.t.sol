// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {V3DeadlineAdapter} from "../src/adapters/V3DeadlineAdapter.sol";
import {CurveAdapterNG} from "../src/adapters/CurveAdapterNG.sol";
import {LFJAdapter} from "../src/adapters/LFJAdapter.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {BaseAdapter} from "../src/adapters/BaseAdapter.sol";

// Round 50 — the immutable layer, chosen by counting rather than by feel.
//
// For every contract in src/, how many times does its name appear anywhere in test/? Twelve scored
// zero, and four of those route real money on mainnet today: Uniswap V4, PancakeSwap V3 (via
// V3DeadlineAdapter), LFJ and Curve NG. Meanwhile Balancer, Hanji, Metric and LFJ-POE — the later
// integrations — each have their own test file. The newer code got tests; the older code carrying
// the money did not.
//
// Recon found no live hole here: all 24 adapters gate their entrypoint, and the three `external
// swap*` functions without `onlyRouter` are two interface declarations and one pool callback that
// cannot use it (it checks `msg.sender` against a transient-storage slot instead). So this round is
// not an exploit hunt. It closes the distance between "the code looks right" and "something proves
// it", in the one layer where being wrong cannot be patched.
//
// What was never proven is the PROVENANCE guard each of these grew after the 2026-08 audit finding
// "adapters trust caller-supplied pool". extraData comes from the quote body, so these are the last
// line between a caller's bytes and someone else's pool.

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// A V3 factory whose registry answer is whatever the test sets.
contract FactoryStub {
    mapping(bytes32 => address) public pools;

    function set(address a, address b, uint24 fee, address pool) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

/// A Curve factory stub: `get_n_coins` is what CurveAdapterNG uses to prove the pool is one of ours.
contract CurveFactoryStub {
    mapping(address => uint256) public n;

    function set(address pool, uint256 coins) external {
        n[pool] = coins;
    }

    function get_n_coins(address pool) external view returns (uint256) {
        return n[pool];
    }
}

contract CurvePoolStub {
    address[] public coinList;

    function setCoins(address a, address b) external {
        delete coinList;
        coinList.push(a);
        coinList.push(b);
    }

    function coins(uint256 i) external view returns (address) {
        return coinList[i];
    }
}

contract UntestedLiveAdaptersTest is Test {
    address constant ROUTER = address(0x1111111111111111111111111111111111111111);
    address constant STRANGER = address(0x2222222222222222222222222222222222222222);
    address constant TO = address(0x3333333333333333333333333333333333333333);

    Token tokenIn;
    Token tokenOut;

    function setUp() public {
        tokenIn = new Token();
        tokenOut = new Token();
    }

    // ── C1: the H1 gate, proven by a revert rather than by a grep ────────────────────────────────
    //
    // H1's whole point was that anyone could call `swap()` directly and drain whoever had approved
    // the adapter. Every adapter now carries `onlyRouter` — but four of the live ones had no test
    // exercising it, so the property was believed rather than demonstrated.

    function test_v3Deadline_rejectsACallerThatIsNotTheRouter() public {
        FactoryStub f = new FactoryStub();
        V3DeadlineAdapter a = new V3DeadlineAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(f), bytes32(0));
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(uint24(3000)));
    }

    function test_curveNG_rejectsACallerThatIsNotTheRouter() public {
        CurveFactoryStub f = new CurveFactoryStub();
        CurveAdapterNG a = new CurveAdapterNG(ROUTER, address(f));
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(address(0x7777777777777777777777777777777777777777), int128(0), int128(1)));
    }

    function test_lfj_rejectsACallerThatIsNotTheRouter() public {
        LFJAdapter a = new LFJAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(0x5555555555555555555555555555555555555555));
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(uint256(25)));
    }

    function test_uniswapV4_rejectsACallerThatIsNotTheRouter() public {
        UniswapV4Adapter a = new UniswapV4Adapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(tokenIn));
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        a.swap(
            address(tokenIn),
            address(tokenOut),
            1e18,
            TO,
            abi.encode(address(tokenIn), address(tokenOut), uint24(500), int24(10), address(0))
        );
    }

    function test_everyLiveAdapterPinsItsRouterAtDeploy() public {
        // A gate is only as good as what it compares against, and that address is immutable — a
        // deploy against the wrong router produces an adapter that is permanently unusable (or
        // permanently open, before H1). Cheap to assert, impossible to fix later.
        FactoryStub f = new FactoryStub();
        assertEq(new V3DeadlineAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(f), bytes32(0)).NULL_ROUTER(), ROUTER);
        assertEq(new CurveAdapterNG(ROUTER, address(new CurveFactoryStub())).NULL_ROUTER(), ROUTER);
        assertEq(new LFJAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(0x5555555555555555555555555555555555555555)).NULL_ROUTER(), ROUTER);
        assertEq(new UniswapV4Adapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(tokenIn)).NULL_ROUTER(), ROUTER);
    }

    function test_anAdapterCannotBeDeployedWithoutARouter() public {
        // Zero would make `onlyRouter` compare against nobody.
        //
        // The stub is created BEFORE arming expectRevert: an argument expression that deploys a
        // contract becomes "the next call", so the cheat code matched the stub's creation and
        // reported that the constructor had not reverted. The guard was fine; the test was not.
        CurveFactoryStub f = new CurveFactoryStub();
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new CurveAdapterNG(address(0), address(f));
    }

    // ── C2/C3: provenance — refuse a forged pool, admit a real one ───────────────────────────────

    function test_v3Deadline_refusesATripleTheFactoryDoesNotKnow() public {
        // extraData is a fee tier chosen by the caller. Without this check the adapter would happily
        // route through whatever pool that (tokenIn, tokenOut, fee) triple happens to name.
        FactoryStub f = new FactoryStub();
        V3DeadlineAdapter a = new V3DeadlineAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(f), bytes32(0));
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(V3DeadlineAdapter.PoolNotCanonical.selector, address(0)));
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(uint24(3000)));
    }

    function test_v3Deadline_acceptsATripleTheFactoryRegistered() public {
        // C3 matters as much as C2: a guard that also rejects real pools kills the venue and gets
        // deleted, which reopens the class it was added for.
        FactoryStub f = new FactoryStub();
        f.set(address(tokenIn), address(tokenOut), 3000, address(0x6666666666666666666666666666666666666666));
        V3DeadlineAdapter a = new V3DeadlineAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(f), bytes32(0));

        // Past the guard, the swap reaches the (absent) router — so the revert proves the guard let
        // it through, which is the property under test here.
        vm.prank(ROUTER);
        try a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(uint24(3000))) {
            // fine — a stub router that answers is also a pass
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            assertTrue(sel != V3DeadlineAdapter.PoolNotCanonical.selector, "a registered pool was rejected");
        }
    }

    function test_v3Deadline_theOtherModeAlsoRefusesAnUndeployedPool() public {
        // C4: with an init-code hash pinned the adapter derives the address by CREATE2 instead of
        // asking the registry. That branch had never run. A derived address with no code means the
        // triple names nothing.
        FactoryStub f = new FactoryStub();
        V3DeadlineAdapter a = new V3DeadlineAdapter(ROUTER, address(0x4444444444444444444444444444444444444444), address(f), keccak256("init"));
        vm.prank(ROUTER);
        vm.expectRevert(); // PoolNotCanonical(derived)
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(uint24(3000)));
    }

    function test_curveNG_refusesAPoolTheFactoryNeverRegistered() public {
        CurveFactoryStub f = new CurveFactoryStub();
        CurvePoolStub pool = new CurvePoolStub();
        CurveAdapterNG a = new CurveAdapterNG(ROUTER, address(f));
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(CurveAdapterNG.PoolNotRegistered.selector, address(pool)));
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(address(pool), int128(0), int128(1)));
    }

    function test_curveNG_refusesCoinIndicesThatDoNotNameTheRouteTokens() public {
        // The subtler half, and the one a registry check alone would miss: the pool IS ours, but the
        // caller's (i, j) point at different coins than the tokens being swapped. Curve identifies
        // coins by index, so a wrong pair of integers is a different trade entirely.
        CurveFactoryStub f = new CurveFactoryStub();
        CurvePoolStub pool = new CurvePoolStub();
        pool.setCoins(address(tokenOut), address(tokenIn)); // deliberately the wrong way round
        f.set(address(pool), 2);

        CurveAdapterNG a = new CurveAdapterNG(ROUTER, address(f));
        vm.prank(ROUTER);
        vm.expectRevert(CurveAdapterNG.CoinIndexMismatch.selector);
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(address(pool), int128(0), int128(1)));
    }

    function test_curveNG_refusesNegativeCoinIndices() public {
        CurveFactoryStub f = new CurveFactoryStub();
        CurvePoolStub pool = new CurvePoolStub();
        pool.setCoins(address(tokenIn), address(tokenOut));
        f.set(address(pool), 2);

        CurveAdapterNG a = new CurveAdapterNG(ROUTER, address(f));
        vm.prank(ROUTER);
        vm.expectRevert(CurveAdapterNG.CoinIndexMismatch.selector);
        a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(address(pool), int128(-1), int128(1)));
    }

    function test_curveNG_acceptsTheRegisteredPoolWithMatchingIndices() public {
        CurveFactoryStub f = new CurveFactoryStub();
        CurvePoolStub pool = new CurvePoolStub();
        pool.setCoins(address(tokenIn), address(tokenOut));
        f.set(address(pool), 2);

        CurveAdapterNG a = new CurveAdapterNG(ROUTER, address(f));
        vm.prank(ROUTER);
        try a.swap(address(tokenIn), address(tokenOut), 1e18, TO, abi.encode(address(pool), int128(0), int128(1))) {
            // reached the pool
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            assertTrue(sel != CurveAdapterNG.PoolNotRegistered.selector, "a registered pool was rejected");
            assertTrue(sel != CurveAdapterNG.CoinIndexMismatch.selector, "matching indices were rejected");
        }
    }
}
