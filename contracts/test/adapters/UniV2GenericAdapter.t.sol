// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {UniV2GenericAdapter} from "../../src/adapters/UniV2GenericAdapter.sol";
import {UniV2DirectAdapter} from "../../src/adapters/UniV2DirectAdapter.sol";

/// @title UniV2GenericAdapter — multi-factory V2 adapter for Robinhood Chain (4663)
/// @notice RH never received the H1 adapter hardening Monad got on 2026-08-05: re-verified on-chain
///         2026-08-05 (chainId asserted 4663 first), its AdapterRegistry holds exactly 5 adapters and
///         the `NotRouter` selector 0x91655201 appears in NONE of the five runtimes. The blocker to
///         simply redeploying the hardened `UniV2DirectAdapter` there is that it pins ONE factory,
///         while engine/src/chain.rs routes EIGHT RH V2 factories through a single `adapter_univ2`
///         field — one hardened redeploy would have broken seven of eight forks.
///
///         The test contract stands in for NullRouter throughout (it is the pinned `NULL_ROUTER`),
///         mirroring production: the router PUSHes tokenIn to the adapter, then calls swap().
///
///         Factory shapes below are not invented — they were measured on RH mainnet 2026-08-05:
///         six forks answer the canonical 2-arg `getPair`, giga_v2 answers ONLY the Solidly 3-arg
///         `getPair(address,address,bool)`, and rh_v2_c answers neither (see RevertingFactory).

// ---------------------------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------------------------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Canonical UniswapV2Factory registry: symmetric 2-arg getPair, zero for unknown pairs.
contract MockV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    function register(address a, address b, address pair) external {
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}

/// @notice Solidly/Velodrome shape (giga_v2 on RH): 3-arg getPair keyed by a `stable` flag, and NO
///         2-arg getPair at all — the 2-arg call hits no function and reverts.
contract MockSolidlyFactory {
    mapping(address => mapping(address => mapping(bool => address))) public pairs;

    function register(address a, address b, bool stable, address pair) external {
        pairs[a][b][stable] = pair;
        pairs[b][a][stable] = pair;
    }

    function getPair(address a, address b, bool stable) external view returns (address) {
        return pairs[a][b][stable];
    }
}

/// @notice The rh_v2_c shape: a "factory" with no usable registry in ANY lookup shape — every
///         getPair call reverts. Pinned before other factories it must not veto them.
contract RevertingFactory {
    fallback() external { revert("NO_REGISTRY"); }
}

/// @notice Honest constant-product pair. Reserves are FIXED (not mutated by swap) so that two
///         adapters can be measured against identical state in the math-parity test.
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public r0;
    uint112 public r1;

    constructor(address t0, address t1, uint112 reserve0, uint112 reserve1) {
        token0 = t0;
        token1 = t1;
        r0 = reserve0;
        r1 = reserve1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) MockERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) MockERC20(token1).transfer(to, amount1Out);
    }
}

/// @notice The H1 primitive: a "pair" that simply KEEPS whatever is pushed to it. UniV2-style
///         adapters transfer the entire input to the extraData address before any callback, so no
///         callback is needed to steal — only the provenance check stops it.
contract HostileV2Pair {
    address public token0;

    constructor(address t0) { token0 = t0; }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (1_000e18, 1_000e18, 0);
    }

    function swap(uint256, uint256, address, bytes calldata) external {}
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

contract UniV2GenericAdapterTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;

    address recipient = address(0xBEEF);
    address stranger = address(0xBAD);

    /// @dev Mirrors RH's routed set: 6 canonical 2-arg forks + 1 Solidly 3-arg fork (giga_v2).
    uint256 constant CANONICAL_FORKS = 6;

    MockV2Factory[] canonical;
    MockSolidlyFactory solidly;
    MockV2Pair[] poolOf; // pool registered in canonical[i]
    MockV2Pair solidlyPool;

    UniV2GenericAdapter adapter;

    function setUp() public {
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        address[] memory factories = new address[](CANONICAL_FORKS + 1);

        for (uint256 i = 0; i < CANONICAL_FORKS; i++) {
            MockV2Factory f = new MockV2Factory();
            MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB), 1_000e18, 2_000e18);
            f.register(address(tokenA), address(tokenB), address(p));
            // Each pair must hold the output it will pay out.
            tokenB.mint(address(p), 1_000e18);
            canonical.push(f);
            poolOf.push(p);
            factories[i] = address(f);
        }

        solidly = new MockSolidlyFactory();
        solidlyPool = new MockV2Pair(address(tokenA), address(tokenB), 1_000e18, 2_000e18);
        solidly.register(address(tokenA), address(tokenB), false, address(solidlyPool));
        tokenB.mint(address(solidlyPool), 1_000e18);
        factories[CANONICAL_FORKS] = address(solidly);

        adapter = new UniV2GenericAdapter(address(this), factories);
    }

    /// @dev The canonical 0.3% curve, computed independently of the adapter.
    function _expectedOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    // -----------------------------------------------------------------------------------------
    // H1 — entrypoint gate
    // -----------------------------------------------------------------------------------------

    /// @dev Before H1 every adapter swap() was world-callable, and this adapter pushes the entire
    ///      input to a caller-named address — a drain primitive for anyone.
    function test_nonRouterCaller_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(poolOf[0])));
    }

    /// @dev The gate must fire BEFORE provenance — a stranger naming a genuinely canonical pool is
    ///      still a stranger.
    function test_nonRouterCaller_reverts_evenForCanonicalPool() public {
        tokenA.mint(address(adapter), 100e18);
        vm.prank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(tokenA), address(tokenB), 100e18, stranger, abi.encode(address(poolOf[3])));
        assertEq(tokenA.balanceOf(address(adapter)), 100e18, "input left the adapter");
    }

    // -----------------------------------------------------------------------------------------
    // Provenance — accept
    // -----------------------------------------------------------------------------------------

    /// @dev THE reason this contract exists: one deployment must fill a pool from EVERY pinned
    ///      factory. The single-factory UniV2DirectAdapter rejects 7 of RH's 8 forks by construction.
    function test_poolFromEveryPinnedFactory_isAccepted() public {
        for (uint256 i = 0; i < CANONICAL_FORKS; i++) {
            uint256 amountIn = 10e18;
            tokenA.mint(address(adapter), amountIn);

            uint256 before = tokenB.balanceOf(recipient);
            uint256 out = adapter.swap(
                address(tokenA), address(tokenB), amountIn, recipient, abi.encode(address(poolOf[i]))
            );

            assertEq(out, _expectedOut(amountIn, 1_000e18, 2_000e18), "wrong amountOut");
            assertEq(tokenB.balanceOf(recipient) - before, out, "recipient credited != returned");
            assertEq(tokenA.balanceOf(address(adapter)), 0, "adapter kept the input");
            assertEq(tokenA.balanceOf(address(poolOf[i])), amountIn, "pair did not receive the input");
        }
    }

    /// @dev giga_v2's shape. It has NO 2-arg getPair on RH mainnet, so the 2-arg probe reverts and
    ///      the 3-arg probe is what must find it.
    function test_solidlyFactory_volatilePair_isAccepted() public {
        uint256 amountIn = 10e18;
        tokenA.mint(address(adapter), amountIn);

        uint256 out = adapter.swap(
            address(tokenA), address(tokenB), amountIn, recipient, abi.encode(address(solidlyPool))
        );

        assertEq(out, _expectedOut(amountIn, 1_000e18, 2_000e18), "wrong amountOut");
        assertEq(tokenB.balanceOf(recipient), out, "recipient not credited");
    }

    /// @dev Reverse direction: tokenB is token1, so zeroForOne = false takes the other reserve branch.
    function test_reverseDirection_isAccepted() public {
        uint256 amountIn = 10e18;
        tokenB.mint(address(adapter), amountIn);
        tokenA.mint(address(poolOf[0]), 1_000e18); // pair must hold the output side

        uint256 out = adapter.swap(
            address(tokenB), address(tokenA), amountIn, recipient, abi.encode(address(poolOf[0]))
        );

        assertEq(out, _expectedOut(amountIn, 2_000e18, 1_000e18), "reverse leg mispriced");
        assertEq(tokenA.balanceOf(recipient), out, "recipient not credited");
    }

    /// @dev A factory with no usable registry (rh_v2_c) sits FIRST in the list and reverts on every
    ///      lookup. Provenance must treat that as a no-match and keep scanning, not bubble the revert.
    function test_revertingFactoryInList_doesNotVetoLaterFactories() public {
        address[] memory factories = new address[](2);
        factories[0] = address(new RevertingFactory());
        factories[1] = address(canonical[0]);
        UniV2GenericAdapter a = new UniV2GenericAdapter(address(this), factories);

        uint256 amountIn = 10e18;
        tokenA.mint(address(a), amountIn);

        uint256 out =
            a.swap(address(tokenA), address(tokenB), amountIn, recipient, abi.encode(address(poolOf[0])));
        assertEq(out, _expectedOut(amountIn, 1_000e18, 2_000e18), "reverting factory vetoed a valid pool");
    }

    // -----------------------------------------------------------------------------------------
    // Provenance — reject
    // -----------------------------------------------------------------------------------------

    /// @dev A REAL, well-formed pool from a factory that simply is not pinned.
    function test_poolFromUnpinnedFactory_isRejected() public {
        MockV2Factory rogue = new MockV2Factory();
        MockV2Pair rev = new MockV2Pair(address(tokenA), address(tokenB), 1_000e18, 2_000e18);
        rogue.register(address(tokenA), address(tokenB), address(rev));
        tokenB.mint(address(rev), 1_000e18);

        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(abi.encodeWithSelector(UniV2GenericAdapter.PoolNotCanonical.selector, address(rev)));
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(rev)));

        assertEq(tokenA.balanceOf(address(rev)), 0, "unpinned pool received the input");
        assertEq(tokenA.balanceOf(address(adapter)), 100e18, "input left the adapter");
    }

    /// @dev The H1 drain: an address no factory claims at all.
    function test_poolNoFactoryClaims_isRejected() public {
        HostileV2Pair hostile = new HostileV2Pair(address(tokenA));
        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(UniV2GenericAdapter.PoolNotCanonical.selector, address(hostile))
        );
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(hostile)));

        assertEq(tokenA.balanceOf(address(hostile)), 0, "hostile pair received the input");
        assertEq(tokenA.balanceOf(address(adapter)), 100e18, "input left the adapter");
    }

    /// @dev address(0) must never be read as a match when a factory answers "no such pair" with zero.
    function test_zeroPool_isRejected() public {
        vm.expectRevert(abi.encodeWithSelector(UniV2GenericAdapter.PoolNotCanonical.selector, address(0)));
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(0)));
    }

    /// @dev A pinned factory's REAL pool, but for a DIFFERENT pair than the router priced. getPair is
    ///      symmetric, so the single lookup binds pool authenticity AND token pair together.
    function test_realPoolOfAnotherPair_isRejected() public {
        MockERC20 tokenC = new MockERC20();
        MockV2Pair other = new MockV2Pair(address(tokenA), address(tokenC), 1_000e18, 2_000e18);
        canonical[0].register(address(tokenA), address(tokenC), address(other));

        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(UniV2GenericAdapter.PoolNotCanonical.selector, address(other))
        );
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(other)));
    }

    /// @dev SAFETY PROPERTY, not an accident: a Solidly "stable" pair prices on x³y+y³x=k and the
    ///      hardcoded 997/1000 constant-product math would misprice it badly. Provenance probes the
    ///      volatile slot ONLY, so a stable pair fails and is refused. giga_v2 has a live stable pair
    ///      (0x1dd24f42…, ~2.65e18/2.83e6 reserves) on RH mainnet today — this is a real case.
    function test_solidlyStablePair_isRejected() public {
        MockV2Pair stablePair = new MockV2Pair(address(tokenA), address(tokenB), 1_000e18, 2_000e18);
        solidly.register(address(tokenA), address(tokenB), true, address(stablePair));
        tokenB.mint(address(stablePair), 1_000e18);

        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(UniV2GenericAdapter.PoolNotCanonical.selector, address(stablePair))
        );
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(stablePair)));

        assertEq(tokenA.balanceOf(address(stablePair)), 0, "stable pair received the input");
    }

    // -----------------------------------------------------------------------------------------
    // Math parity with the live single-factory adapter
    // -----------------------------------------------------------------------------------------

    /// @dev The swap math is carried over VERBATIM from UniV2DirectAdapter — only provenance changed.
    ///      Both adapters run against the SAME factory and the SAME pool (mock reserves are fixed, so
    ///      the second swap sees identical state) and must return the identical amountOut.
    function test_swapMath_matchesUniV2DirectAdapter() public {
        UniV2DirectAdapter direct = new UniV2DirectAdapter(address(this), address(canonical[0]));

        uint256 amountIn = 37.5e18;
        tokenB.mint(address(poolOf[0]), 1_000e18); // fund both payouts

        tokenA.mint(address(direct), amountIn);
        uint256 outDirect =
            direct.swap(address(tokenA), address(tokenB), amountIn, recipient, abi.encode(address(poolOf[0])));

        tokenA.mint(address(adapter), amountIn);
        uint256 outGeneric =
            adapter.swap(address(tokenA), address(tokenB), amountIn, recipient, abi.encode(address(poolOf[0])));

        assertEq(outGeneric, outDirect, "generic adapter diverged from the live adapter's math");
        assertEq(outGeneric, _expectedOut(amountIn, 1_000e18, 2_000e18), "not the canonical 0.3% curve");
    }

    /// @dev Parity must hold across magnitudes and both directions, not just one sample.
    function testFuzz_swapMath_matchesUniV2DirectAdapter(uint96 rawAmountIn, bool reverse) public {
        uint256 amountIn = uint256(rawAmountIn) % 500e18 + 1;
        UniV2DirectAdapter direct = new UniV2DirectAdapter(address(this), address(canonical[1]));

        MockERC20 tIn = reverse ? tokenB : tokenA;
        MockERC20 tOut = reverse ? tokenA : tokenB;
        tOut.mint(address(poolOf[1]), 5_000e18);

        tIn.mint(address(direct), amountIn);
        uint256 outDirect =
            direct.swap(address(tIn), address(tOut), amountIn, recipient, abi.encode(address(poolOf[1])));

        tIn.mint(address(adapter), amountIn);
        uint256 outGeneric =
            adapter.swap(address(tIn), address(tOut), amountIn, recipient, abi.encode(address(poolOf[1])));

        assertEq(outGeneric, outDirect, "math diverged from the live adapter");
        assertEq(
            outGeneric,
            reverse ? _expectedOut(amountIn, 2_000e18, 1_000e18) : _expectedOut(amountIn, 1_000e18, 2_000e18),
            "not the canonical 0.3% curve"
        );
    }

    // -----------------------------------------------------------------------------------------
    // Constructor guards
    // -----------------------------------------------------------------------------------------

    function test_constructor_rejectsEmptyFactoryList() public {
        address[] memory none = new address[](0);
        vm.expectRevert(UniV2GenericAdapter.EmptyFactoryList.selector);
        new UniV2GenericAdapter(address(this), none);
    }

    function test_constructor_rejectsZeroFactory() public {
        address[] memory factories = new address[](2);
        factories[0] = address(canonical[0]);
        factories[1] = address(0);
        vm.expectRevert(UniV2GenericAdapter.ZeroFactory.selector);
        new UniV2GenericAdapter(address(this), factories);
    }

    function test_constructor_rejectsZeroRouter() public {
        address[] memory factories = new address[](1);
        factories[0] = address(canonical[0]);
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new UniV2GenericAdapter(address(0), factories);
    }

    function test_constructor_pinsRouterAndFactories() public view {
        assertEq(adapter.NULL_ROUTER(), address(this), "router not pinned");
        assertEq(adapter.factoriesLength(), CANONICAL_FORKS + 1, "factory count");
        assertEq(adapter.factories(0), address(canonical[0]), "factory order not preserved");
        assertEq(adapter.factories(CANONICAL_FORKS), address(solidly), "solidly factory missing");
    }
}
