// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MetricV1Adapter, IMetricV1SimpleRouter} from "../src/adapters/MetricV1Adapter.sol";
import {ChordMetricV1Adapter} from "../src/chord/ChordMetricV1Adapter.sol";
import {BaseAdapter} from "../src/adapters/BaseAdapter.sol";

/// Minimal ERC20 with allowance semantics — Metric's SimpleRouter pulls via transferFrom.
contract V1MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        require(allowance[from][msg.sender] >= amt, "ALLOW");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// A v1 pool as the adapter sees it: `getImmutables()` whose first three words are factory, token0, token1 — followed
/// by 21 more words, as on-chain (the real struct has 24 static fields; read on Monad 2026-10-11).
contract V1MockPool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    constructor(address factory_, address token0_, address token1_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
    }

    function getImmutables() external view returns (uint256[24] memory w) {
        w[0] = uint256(uint160(factory));
        w[1] = uint256(uint160(token0));
        w[2] = uint256(uint160(token1));
        w[3] = 1; // token0ScaleMultiplier
        w[4] = 1e12; // token1ScaleMultiplier
    }
}

/// A contract that answers `getImmutables()` like a pool but that the factory never created.
contract V1ImpostorPool is V1MockPool {
    constructor(address factory_, address token0_, address token1_) V1MockPool(factory_, token0_, token1_) {}
}

/// A "pool" whose `getImmutables()` answers too little.
contract V1ShortPool {
    function getImmutables() external pure returns (address) {
        return address(1);
    }
}

contract V1MockFactory {
    mapping(address => bool) public isPool;

    function register(address pool) external {
        isPool[pool] = true;
    }
}

/// Metric v1 SimpleRouter as the adapter depends on it: pulls `tokenIn` from msg.sender (all of it, or a configured
/// fraction), pays `tokenOut` to `recipient`, and is called with the SDK's no-bound price limits.
contract V1MockSimpleRouter {
    uint256 public rate; // amountOut = used * rate / 1e18
    uint256 public useRatio = 1e18;
    bool public noFill;
    address public lastRecipient;
    address public lastPool;
    bytes public lastExtensionData;

    function setRate(uint256 r) external {
        rate = r;
    }

    function setUseRatio(uint256 r) external {
        useRatio = r;
    }

    function setNoFill(bool v) external {
        noFill = v;
    }

    function exactInputSingle(IMetricV1SimpleRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(block.timestamp <= p.deadline, "MOCK_EXPIRED");
        require(p.priceLimitX64 == (p.zeroForOne ? 0 : type(uint128).max), "MOCK_BAD_LIMIT");
        require(p.amountOutMinimum == 0, "MOCK_MIN");
        V1MockPool pool = V1MockPool(p.pool);
        require(p.tokenIn == (p.zeroForOne ? pool.token0() : pool.token1()), "MOCK_TOKEN_IN");
        require(p.tokenOut == (p.zeroForOne ? pool.token1() : pool.token0()), "MOCK_TOKEN_OUT");
        lastRecipient = p.recipient;
        lastPool = p.pool;
        lastExtensionData = p.extensionData;
        if (noFill) return 0;
        uint256 used = (uint256(p.amountIn) * useRatio) / 1e18;
        require(V1MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), used), "PULL");
        amountOut = (used * rate) / 1e18;
        require(V1MockERC20(p.tokenOut).transfer(p.recipient, amountOut), "PAY");
    }
}

contract MetricV1AdapterTest is Test {
    V1MockERC20 wmon; // token0, 18 decimals
    V1MockERC20 usdc; // token1, 6 decimals
    V1MockFactory factory;
    V1MockPool pool;
    V1MockSimpleRouter router;
    MetricV1Adapter adapter;

    address recipient = address(0xDEAD);

    function setUp() public {
        wmon = new V1MockERC20();
        usdc = new V1MockERC20();
        factory = new V1MockFactory();
        pool = new V1MockPool(address(factory), address(wmon), address(usdc));
        factory.register(address(pool));
        router = new V1MockSimpleRouter();
        // The test contract stands in for the Chord router (H1 entry gate).
        adapter = new MetricV1Adapter(address(this), address(router), address(factory));
        wmon.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    function _swap(address tin, address tout, uint256 amt) internal returns (uint256) {
        return adapter.swap(tin, tout, amt, recipient, abi.encode(address(pool)));
    }

    function test_sellToken0_fullFill() public {
        router.setRate(0.0274e6); // 1 WMON (1e18) -> 0.0274 USDC (27_400 raw)
        wmon.mint(address(adapter), 1_000e18);
        uint256 out = _swap(address(wmon), address(usdc), 1_000e18);
        assertEq(out, 27_400_000); // 27.4 USDC
        assertEq(usdc.balanceOf(recipient), out);
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wmon.allowance(address(adapter), address(router)), 0, "approval is cleared");
        assertEq(router.lastRecipient(), address(adapter), "the venue pays the adapter, which measures the delta");
        assertEq(router.lastPool(), address(pool));
        assertEq(router.lastExtensionData().length, 0);
    }

    function test_sellToken1_fullFill() public {
        router.setRate(36.5e30); // 1 USDC raw unit (1e-6) -> 36.5e12 raw WMON
        usdc.mint(address(adapter), 1_000e6);
        uint256 out = _swap(address(usdc), address(wmon), 1_000e6);
        assertEq(out, 36_500e18);
        assertEq(wmon.balanceOf(recipient), out);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }

    function test_partialFill_forwardsLeftoverInput() public {
        router.setRate(0.0274e6);
        router.setUseRatio(0.6e18);
        wmon.mint(address(adapter), 1_000e18);
        uint256 out = _swap(address(wmon), address(usdc), 1_000e18);
        assertEq(out, 16_440_000); // 600 WMON at the rate
        assertEq(wmon.balanceOf(recipient), 400e18, "the unused input leaves with the output");
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(wmon.allowance(address(adapter), address(router)), 0);
    }

    function test_outputAlreadyOnAdapter_isNotCounted() public {
        router.setRate(0.0274e6);
        usdc.mint(address(adapter), 5e6); // stray balance from before
        wmon.mint(address(adapter), 1_000e18);
        uint256 out = _swap(address(wmon), address(usdc), 1_000e18);
        assertEq(out, 27_400_000, "only this swap's proceeds are reported and forwarded");
        assertEq(usdc.balanceOf(recipient), 27_400_000);
    }

    function test_noFill_reverts() public {
        router.setNoFill(true);
        wmon.mint(address(adapter), 1e18);
        vm.expectRevert(MetricV1Adapter.NoFill.selector);
        _swap(address(wmon), address(usdc), 1e18);
    }

    function test_poolNotInFactory_reverts() public {
        V1ImpostorPool fake = new V1ImpostorPool(address(factory), address(wmon), address(usdc));
        wmon.mint(address(adapter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MetricV1Adapter.NotMetricPool.selector, address(fake)));
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(fake)));
    }

    function test_pairMismatch_reverts() public {
        V1MockERC20 other = new V1MockERC20();
        other.mint(address(adapter), 1e18);
        vm.expectRevert(MetricV1Adapter.PairMismatch.selector);
        _swap(address(other), address(usdc), 1e18);
        vm.expectRevert(MetricV1Adapter.PairMismatch.selector);
        _swap(address(wmon), address(wmon), 1e18);
    }

    function test_shortImmutables_reverts() public {
        V1ShortPool short = new V1ShortPool();
        factory.register(address(short));
        vm.expectRevert(MetricV1Adapter.BadImmutables.selector);
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(short)));
    }

    function test_amountAboveUint128_reverts() public {
        vm.expectRevert(MetricV1Adapter.AmountTooLarge.selector);
        _swap(address(wmon), address(usdc), uint256(type(uint128).max) + 1);
    }

    function test_onlyRouter() public {
        wmon.mint(address(adapter), 1e18);
        vm.prank(address(0xBEEF));
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(pool)));
    }

    function test_notPrefunded_reverts() public {
        router.setRate(0.0274e6);
        vm.expectRevert(bytes("BAL"));
        _swap(address(wmon), address(usdc), 1e18);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new MetricV1Adapter(address(0), address(router), address(factory));
        vm.expectRevert(MetricV1Adapter.ZeroAddress.selector);
        new MetricV1Adapter(address(this), address(0), address(factory));
        vm.expectRevert(MetricV1Adapter.ZeroAddress.selector);
        new MetricV1Adapter(address(this), address(router), address(0));
    }

    function test_chordName_isTheSameAdapter() public {
        ChordMetricV1Adapter c = new ChordMetricV1Adapter(address(this), address(router), address(factory));
        assertEq(c.NULL_ROUTER(), address(this));
        assertEq(address(c.ROUTER()), address(router));
        assertEq(address(c.FACTORY()), address(factory));
        router.setRate(0.0274e6);
        wmon.mint(address(c), 100e18);
        uint256 out = c.swap(address(wmon), address(usdc), 100e18, recipient, abi.encode(address(pool)));
        assertEq(out, 2_740_000);
    }

    function testFuzz_adapterEndsEmpty(uint96 amountIn, uint64 ratio) public {
        amountIn = uint96(bound(amountIn, 1e12, 100_000e18));
        ratio = uint64(bound(ratio, 0.01e18, 1e18));
        router.setRate(0.0274e6);
        router.setUseRatio(ratio);
        wmon.mint(address(adapter), amountIn);
        uint256 used = (uint256(amountIn) * ratio) / 1e18;
        if ((used * 0.0274e6) / 1e18 == 0) {
            vm.expectRevert(MetricV1Adapter.NoFill.selector);
            _swap(address(wmon), address(usdc), amountIn);
            return;
        }
        _swap(address(wmon), address(usdc), amountIn);
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wmon.allowance(address(adapter), address(router)), 0);
        assertEq(wmon.balanceOf(recipient), uint256(amountIn) - used);
    }
}
