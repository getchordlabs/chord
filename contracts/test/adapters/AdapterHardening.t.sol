// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter, AllowlistAdapter} from "../../src/adapters/BaseAdapter.sol";
import {UniV3GenericAdapter} from "../../src/adapters/UniV3GenericAdapter.sol";
import {AlgebraAdapter} from "../../src/adapters/AlgebraAdapter.sol";
import {UniV2DirectAdapter} from "../../src/adapters/UniV2DirectAdapter.sol";
import {NadFunPairAdapter} from "../../src/adapters/NadFunPairAdapter.sol";
import {NadFunBCAdapter} from "../../src/adapters/NadFunBCAdapter.sol";
import {NadFunV2Adapter} from "../../src/adapters/NadFunV2Adapter.sol";
import {LfjPoeAdapter} from "../../src/adapters/LfjPoeAdapter.sol";
import {MetricAdapter} from "../../src/adapters/MetricAdapter.sol";
import {HanjiAdapter} from "../../src/adapters/HanjiAdapter.sol";
import {KuruAdapter} from "../../src/adapters/KuruAdapter.sol";
import {MentoAdapter} from "../../src/adapters/MentoAdapter.sol";

/// @title Adapter hardening regressions — 2026-08-05 audit H1 (+ M5, M9, and the Algebra sign check)
/// @notice Every test here FAILS on the pre-fix adapters: before H1 each `swap()` was world-callable
///         and each destination/pool address came out of caller-supplied `extraData` unvalidated, so
///         "hostile pool" and "stranger calls swap" were both SUCCESSFUL paths, not reverts.
///
///         The test contract stands in for NullRouter throughout (it is the pinned `NULL_ROUTER`),
///         mirroring production: the router PUSHes tokenIn to the adapter, then calls swap().

// ---------------------------------------------------------------------------------------------
// Shared minimal mocks
// ---------------------------------------------------------------------------------------------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IAlgebraCallback {
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice V3 factory registry (the `initCodeHash == 0` lane the adapters consult).
contract MockV3Factory {
    mapping(bytes32 => address) internal pools;

    function register(address token0, address token1, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(token0, token1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

/// @notice Honest V3 pool: pulls the consumed input via the callback, pays the output to `recipient`.
///         `fillBps` < 10000 models a thin pool that terminates early (the M5 partial-fill case).
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    uint256 public fillBps = 10_000;
    uint256 public rateBps = 5_000; // out = consumed * rateBps / 10000

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setFillBps(uint256 bps) external { fillBps = bps; }
    /// @dev Models a DYNAMIC-FEE fork: the live fee drifts away from the creation fee it was keyed by.
    function setFee(uint24 f) external { fee = f; }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 consumed = (uint256(amountSpecified) * fillBps) / 10_000;
        uint256 out = (consumed * rateBps) / 10_000;

        (amount0, amount1) = zeroForOne
            ? (int256(consumed), -int256(out))
            : (-int256(out), int256(consumed));

        IV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        MockERC20(zeroForOne ? token1 : token0).transfer(recipient, out);
    }
}

/// @notice The H1 primitive: a "pool" that names BOTH the token and the amount in the callback and
///         keeps whatever the adapter is holding. It answers token0/token1/fee so it survives every
///         check that trusts the pool's own word.
contract HostileV3Pool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    address public loot;
    uint256 public amount;

    constructor(address t0, address t1, address loot_, uint256 amount_) {
        token0 = t0;
        token1 = t1;
        loot = loot_;
        amount = amount_;
    }

    function swap(address, bool, int256, uint160, bytes calldata)
        external
        returns (int256, int256)
    {
        // The callback pays `amount` of `loot` to msg.sender — i.e. to this contract.
        IV3Callback(msg.sender).uniswapV3SwapCallback(int256(amount), int256(-1), abi.encode(loot));
        return (int256(amount), int256(-1));
    }
}

/// @notice Algebra factory registry (`poolByPair`, both orderings, as the real factory writes them).
contract MockAlgebraFactory {
    mapping(address => mapping(address => address)) public poolByPair;

    function register(address a, address b, address pool) external {
        poolByPair[a][b] = pool;
        poolByPair[b][a] = pool;
    }
}

/// @notice Algebra pool. `evilPositiveOut` returns a POSITIVE output delta — the (c) sign-check case
///         that used to make `uint256(-amount1)` evaluate to type(uint256).max.
contract MockAlgebraPool {
    address public token0;
    address public token1;
    uint256 public fillBps = 10_000;
    bool public evilPositiveOut;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setFillBps(uint256 bps) external { fillBps = bps; }
    function setEvilPositiveOut(bool v) external { evilPositiveOut = v; }

    function swap(address recipient, bool zeroToOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 consumed = (uint256(amountSpecified) * fillBps) / 10_000;

        if (evilPositiveOut) {
            IAlgebraCallback(msg.sender).algebraSwapCallback(int256(consumed), int256(1), data);
            return (int256(consumed), int256(1));
        }

        uint256 out = consumed / 2;
        (amount0, amount1) = zeroToOne
            ? (int256(consumed), -int256(out))
            : (-int256(out), int256(consumed));
        IAlgebraCallback(msg.sender).algebraSwapCallback(amount0, amount1, data);
        MockERC20(zeroToOne ? token1 : token0).transfer(recipient, out);
    }
}

/// @notice V2-style pair registry.
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

/// @notice A "pair" that simply keeps whatever is pushed to it (UniV2Direct/NadFunPair transfer the
///         entire input to the extraData address BEFORE any swap call — no callback needed to steal).
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

contract AdapterHardeningTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;

    address recipient = address(0xDEAD);
    address stranger = address(0xBAD);
    address dummy = address(0xD1);

    function setUp() public {
        tokenA = new MockERC20();
        tokenB = new MockERC20();
    }

    function _v3Adapter(address factory) internal returns (UniV3GenericAdapter) {
        address[] memory factories = new address[](1);
        factories[0] = factory;
        bytes32[] memory hashes = new bytes32[](1); // zero → registry lane
        uint24[] memory tiers = new uint24[](2); // creation-fee candidates (dynamic-fee forks)
        tiers[0] = 500;
        tiers[1] = 3000;
        return new UniV3GenericAdapter(address(this), factories, hashes, tiers);
    }

    function _sorted() internal view returns (address t0, address t1) {
        (t0, t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
    }

    // -----------------------------------------------------------------------------------------
    // H1(a) — entrypoint gate: nothing but NullRouter may call swap()
    // -----------------------------------------------------------------------------------------

    function test_v3Generic_nonRouterCaller_reverts() public {
        MockV3Factory factory = new MockV3Factory();
        UniV3GenericAdapter adapter = _v3Adapter(address(factory));

        vm.prank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(0x1234)));
    }

    function test_algebra_nonRouterCaller_reverts() public {
        AlgebraAdapter adapter = new AlgebraAdapter(address(this), address(new MockAlgebraFactory()));

        vm.prank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(0x1234)));
    }

    function test_univ2Direct_nonRouterCaller_reverts() public {
        UniV2DirectAdapter adapter = new UniV2DirectAdapter(address(this), address(new MockV2Factory()));

        vm.prank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(0x1234)));
    }

    function test_allowlistVenues_nonRouterCaller_reverts() public {
        address[] memory pools = new address[](1);
        pools[0] = dummy;

        LfjPoeAdapter poe = new LfjPoeAdapter(address(this), pools);
        MetricAdapter metric = new MetricAdapter(address(this), dummy, pools);
        HanjiAdapter hanji = new HanjiAdapter(address(this), dummy, pools);
        KuruAdapter kuru = new KuruAdapter(address(this), dummy, dummy, pools);

        vm.startPrank(stranger);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        poe.swap(address(tokenA), address(tokenB), 1, recipient, abi.encode(dummy));
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        metric.swap(address(tokenA), address(tokenB), 1, recipient, abi.encode(dummy));
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        hanji.swap(address(tokenA), address(tokenB), 1, recipient, abi.encode(dummy));
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        kuru.swap(address(tokenA), address(tokenB), 1, recipient, abi.encode(dummy, true, false));
        vm.stopPrank();
    }

    function test_constructor_rejectsZeroRouter() public {
        address[] memory pools = new address[](1);
        pools[0] = dummy;
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new LfjPoeAdapter(address(0), pools);
    }

    // -----------------------------------------------------------------------------------------
    // H1(b) — pool provenance: a hostile pool in extraData can no longer be reached
    // -----------------------------------------------------------------------------------------

    /// @dev THE H1 primitive. Pre-fix this call SUCCEEDED and moved the adapter's whole balance to a
    ///      caller-chosen contract: the transient callback gate was armed to the hostile pool itself,
    ///      and `_settle` took both the token and the amount from that pool's callback arguments.
    function test_v3Generic_hostilePool_cannotDrainSeededBalance() public {
        MockV3Factory factory = new MockV3Factory();
        UniV3GenericAdapter adapter = _v3Adapter(address(factory));

        uint256 seeded = 500e18; // dust left on the adapter between transactions
        tokenA.mint(address(adapter), seeded);

        HostileV3Pool hostile =
            new HostileV3Pool(address(tokenA), address(tokenB), address(tokenA), seeded);

        vm.expectRevert(
            abi.encodeWithSelector(UniV3GenericAdapter.PoolNotCanonical.selector, address(hostile))
        );
        adapter.swap(address(tokenA), address(tokenB), 0, recipient, abi.encode(address(hostile)));

        assertEq(tokenA.balanceOf(address(adapter)), seeded, "balance drained");
        assertEq(tokenA.balanceOf(address(hostile)), 0, "hostile pool got paid");
    }

    /// @dev The honest path still works — provenance must not break real routing.
    function test_v3Generic_registeredPool_swapsAndSweeps() public {
        MockV3Factory factory = new MockV3Factory();
        UniV3GenericAdapter adapter = _v3Adapter(address(factory));

        (address t0, address t1) = _sorted();
        MockV3Pool pool = new MockV3Pool(t0, t1);
        factory.register(t0, t1, pool.fee(), address(pool));
        MockERC20(t1).mint(address(pool), 1_000e18);
        MockERC20(t0).mint(address(pool), 1_000e18);

        MockERC20(t0).mint(address(adapter), 100e18);
        uint256 out = adapter.swap(t0, t1, 100e18, recipient, abi.encode(address(pool)));

        assertEq(out, 50e18, "amountOut");
        assertEq(MockERC20(t1).balanceOf(recipient), 50e18, "recipient credited");
        assertEq(MockERC20(t0).balanceOf(address(adapter)), 0, "input stuck on adapter");
    }

    /// @dev DYNAMIC-FEE FORK REGRESSION. Measured on Monad 2026-08-05: PangolinV3's AUSD/WMON pool
    ///      answers `fee() == 10` while its factory registered it under 2500. A provenance check that
    ///      keys off the pool's LIVE fee therefore rejects a perfectly real pool — i.e. it would take
    ///      a whole venue offline. The pinned creation-fee tiers are what make this pass.
    function test_v3Generic_dynamicFeePool_stillPassesProvenance() public {
        MockV3Factory factory = new MockV3Factory();
        UniV3GenericAdapter adapter = _v3Adapter(address(factory));

        (address t0, address t1) = _sorted();
        MockV3Pool pool = new MockV3Pool(t0, t1);
        factory.register(t0, t1, 3000, address(pool)); // created at 3000 …
        pool.setFee(10); // … but reports 10 today
        MockERC20(t1).mint(address(pool), 1_000e18);

        MockERC20(t0).mint(address(adapter), 100e18);
        uint256 out = adapter.swap(t0, t1, 100e18, recipient, abi.encode(address(pool)));

        assertEq(out, 50e18, "dynamic-fee pool rejected by provenance");
    }

    /// @dev M5: a partial fill must leave NOTHING on an immutable, ownerless adapter.
    function test_v3Generic_partialFill_sweepsRemainder() public {
        MockV3Factory factory = new MockV3Factory();
        UniV3GenericAdapter adapter = _v3Adapter(address(factory));

        (address t0, address t1) = _sorted();
        MockV3Pool pool = new MockV3Pool(t0, t1);
        pool.setFillBps(6_000); // thin pool: consumes 60%, leaves 40% behind
        factory.register(t0, t1, pool.fee(), address(pool));
        MockERC20(t1).mint(address(pool), 1_000e18);

        MockERC20(t0).mint(address(adapter), 100e18);
        uint256 out = adapter.swap(t0, t1, 100e18, recipient, abi.encode(address(pool)));

        assertEq(out, 30e18, "amountOut for the filled part");
        assertEq(MockERC20(t0).balanceOf(address(adapter)), 0, "remainder stranded on adapter");
        assertEq(MockERC20(t0).balanceOf(recipient), 40e18, "remainder returned to `to`");
    }

    function test_algebra_unregisteredPool_reverts() public {
        MockAlgebraFactory factory = new MockAlgebraFactory();
        AlgebraAdapter adapter = new AlgebraAdapter(address(this), address(factory));

        uint256 seeded = 10e18;
        tokenA.mint(address(adapter), seeded);
        MockAlgebraPool hostile = new MockAlgebraPool(address(tokenA), address(tokenB));

        vm.expectRevert(
            abi.encodeWithSelector(AlgebraAdapter.PoolNotRegistered.selector, address(hostile))
        );
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(address(hostile)));
        assertEq(tokenA.balanceOf(address(adapter)), seeded, "balance touched");
    }

    /// @dev (c) AlgebraAdapter:72 computed uint256(-amount1) with NO sign check — a pool returning +1
    ///      yielded type(uint256).max, i.e. an adapter reporting an infinite fill to the router.
    function test_algebra_positiveOutputDelta_reverts() public {
        MockAlgebraFactory factory = new MockAlgebraFactory();
        AlgebraAdapter adapter = new AlgebraAdapter(address(this), address(factory));

        (address t0, address t1) = _sorted();
        MockAlgebraPool pool = new MockAlgebraPool(t0, t1);
        pool.setEvilPositiveOut(true);
        factory.register(t0, t1, address(pool));

        MockERC20(t0).mint(address(adapter), 10e18);

        vm.expectRevert(bytes("ALGEBRA_NO_OUTPUT"));
        adapter.swap(t0, t1, 10e18, recipient, abi.encode(address(pool)));
    }

    /// @dev M5 for the Algebra sibling.
    function test_algebra_partialFill_sweepsRemainder() public {
        MockAlgebraFactory factory = new MockAlgebraFactory();
        AlgebraAdapter adapter = new AlgebraAdapter(address(this), address(factory));

        (address t0, address t1) = _sorted();
        MockAlgebraPool pool = new MockAlgebraPool(t0, t1);
        pool.setFillBps(5_000);
        factory.register(t0, t1, address(pool));
        MockERC20(t1).mint(address(pool), 1_000e18);

        MockERC20(t0).mint(address(adapter), 100e18);
        uint256 out = adapter.swap(t0, t1, 100e18, recipient, abi.encode(address(pool)));

        assertEq(out, 25e18, "amountOut for the filled part");
        assertEq(MockERC20(t0).balanceOf(address(adapter)), 0, "remainder stranded on adapter");
        assertEq(MockERC20(t0).balanceOf(recipient), 50e18, "remainder returned to `to`");
    }

    /// @dev UniV2Direct:52 transferred the ENTIRE input to the extraData address with no callback and
    ///      no validation — the simplest form of the H1 primitive.
    function test_univ2Direct_hostilePair_cannotReceiveInput() public {
        MockV2Factory factory = new MockV2Factory();
        UniV2DirectAdapter adapter = new UniV2DirectAdapter(address(this), address(factory));

        HostileV2Pair hostile = new HostileV2Pair(address(tokenA));
        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(UniV2DirectAdapter.NotFactoryPair.selector, address(hostile))
        );
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(hostile)));

        assertEq(tokenA.balanceOf(address(hostile)), 0, "hostile pair received the input");
        assertEq(tokenA.balanceOf(address(adapter)), 100e18, "input left the adapter");
    }

    /// @dev NadFunPairAdapter:67 — same unconditional safeTransfer, now bound to the factory's pair.
    function test_nadFunPair_hostilePair_cannotReceiveInput() public {
        MockV2Factory factory = new MockV2Factory();
        NadFunPairAdapter adapter =
            new NadFunPairAdapter(address(this), address(tokenA), address(factory));

        HostileV2Pair hostile = new HostileV2Pair(address(tokenA));
        tokenA.mint(address(adapter), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(NadFunPairAdapter.NotFactoryPair.selector, address(hostile))
        );
        adapter.swap(address(tokenA), address(tokenB), 100e18, recipient, abi.encode(address(hostile)));

        assertEq(tokenA.balanceOf(address(hostile)), 0, "hostile pair received the input");
    }

    /// @dev Registry-less venues (POE / Metric / Hanji / Kuru): anything outside the construction-time
    ///      allowlist is rejected BEFORE the adapter reads or approves anything.
    function test_allowlistVenues_unknownPool_reverts() public {
        address[] memory pools = new address[](1);
        pools[0] = dummy;
        address hostile = address(0xDEADBEEF);

        LfjPoeAdapter poe = new LfjPoeAdapter(address(this), pools);
        MetricAdapter metric = new MetricAdapter(address(this), dummy, pools);
        HanjiAdapter hanji = new HanjiAdapter(address(this), dummy, pools);
        KuruAdapter kuru = new KuruAdapter(address(this), dummy, dummy, pools);

        bytes memory expected =
            abi.encodeWithSelector(AllowlistAdapter.PoolNotAllowed.selector, hostile);

        vm.expectRevert(expected);
        poe.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(hostile));
        vm.expectRevert(expected);
        metric.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(hostile));
        vm.expectRevert(expected);
        hanji.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(hostile));
        vm.expectRevert(expected);
        kuru.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(hostile, true, false));
    }

    /// @dev Mento: the extraData `factory` is what the venue router uses to LOOK UP the pool it pulls
    ///      the input into — a caller-supplied factory chose the destination of the whole amount.
    function test_mento_foreignFactory_reverts() public {
        MentoAdapter adapter = new MentoAdapter(address(this), dummy, dummy);
        address hostileFactory = address(0xF00D);

        vm.expectRevert(
            abi.encodeWithSelector(MentoAdapter.FactoryNotPinned.selector, hostileFactory)
        );
        adapter.swap(address(tokenA), address(tokenB), 1e18, recipient, abi.encode(hostileFactory));
    }

    // -----------------------------------------------------------------------------------------
    // M9 — nad.fun `token` was unbound to the route
    // -----------------------------------------------------------------------------------------

    /// @dev NadFunBCAdapter:73 returned a balanceOf delta OF `token` that the router consumed as an
    ///      amount of `route.tokenOut`. Nothing tied the two, and nothing required tokenIn == WMON
    ///      before unwrapping it.
    function test_nadFunBC_tokenUnboundToRoute_reverts() public {
        address wmon = address(tokenA);
        NadFunBCAdapter adapter = new NadFunBCAdapter(address(this), dummy, wmon);
        address someOtherToken = address(0xC0FFEE);

        // buy: `token` must be tokenOut and tokenIn must be WMON.
        vm.expectRevert(NadFunBCAdapter.TokenNotBoundToRoute.selector);
        adapter.swap(wmon, address(tokenB), 1e18, recipient, abi.encode(someOtherToken, true));

        // buy with a non-WMON input is equally rejected (the unwrap would otherwise run blind).
        vm.expectRevert(NadFunBCAdapter.TokenNotBoundToRoute.selector);
        adapter.swap(address(tokenB), someOtherToken, 1e18, recipient, abi.encode(someOtherToken, true));

        // sell: `token` must be tokenIn and tokenOut must be WMON.
        vm.expectRevert(NadFunBCAdapter.TokenNotBoundToRoute.selector);
        adapter.swap(someOtherToken, address(tokenB), 1e18, recipient, abi.encode(someOtherToken, false));
    }

    function test_nadFunV2_tokenUnboundToRoute_reverts() public {
        address wmon = address(tokenA);
        NadFunV2Adapter adapter = new NadFunV2Adapter(address(this), dummy, wmon);

        vm.expectRevert(NadFunV2Adapter.TokenNotBoundToRoute.selector);
        adapter.swap(wmon, address(tokenB), 1e18, recipient, abi.encode(address(0xC0FFEE), true));
    }
}
