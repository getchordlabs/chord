// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MetricAdapter} from "../src/adapters/MetricAdapter.sol";

/// Minimal ERC20 with allowance semantics — the Metric router pulls via transferFrom.
contract MockERC20 {
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

/// OMM pool mock — only token0/token1 of getImmutables matter to the adapter.
contract MockMetricPool {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getImmutables()
        external
        view
        returns (
            address,
            address,
            address,
            address,
            uint104,
            uint104,
            uint104,
            bool,
            uint256,
            uint256,
            int16,
            int16,
            uint256,
            uint256
        )
    {
        return (address(0), address(0), token0, token1, 0, 0, 0, false, 0, 0, 0, 0, 0, 0);
    }
}

/// Mimics the Metric shared SwapRouter semantics the adapter depends on:
/// - Pulls via transferFrom exactly amountInUsed (= amountIn * useRatio, configurable partial —
///   the unused approval remainder stays on the caller).
/// - Sends amountOut of tokenOut to `recipient`, returns (amountOut, amountInUsed).
/// - No-fill mode returns (0, 0) without pulling anything and without reverting.
/// - Locks the adapter's no-bound priceLimitX64 sentinels (1 down / max up) per direction.
contract MockMetricRouter {
    uint256 public rate; // amountOut = used * rate / 1e18
    uint256 public useRatio = 1e18; // fraction of amountIn actually consumed
    bool public noFill;

    function setRate(uint256 r) external {
        rate = r;
    }

    function setUseRatio(uint256 r) external {
        useRatio = r;
    }

    function setNoFill(bool v) external {
        noFill = v;
    }

    function swapExactInput(
        address pool,
        address recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 priceLimitX64,
        uint256, // minAmountOut
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
        require(block.timestamp <= deadline, "MOCK_EXPIRED");
        require(priceLimitX64 == (zeroForOne ? 1 : type(uint128).max), "MOCK_BAD_LIMIT");
        if (noFill) return (0, 0);

        (,, address t0, address t1,,,,,,,,,,) = MockMetricPool(pool).getImmutables();
        (address tin, address tout) = zeroForOne ? (t0, t1) : (t1, t0);

        amountInUsed = (uint256(amountIn) * useRatio) / 1e18;
        require(MockERC20(tin).transferFrom(msg.sender, address(this), amountInUsed), "PULL");
        amountOut = (amountInUsed * rate) / 1e18;
        require(MockERC20(tout).transfer(recipient, amountOut), "PAY");
    }
}

contract MetricAdapterTest is Test {
    MockERC20 wmon; // token0, 18-dec
    MockERC20 usdc; // token1, 6-dec
    MockMetricPool pool;
    MockMetricRouter router;
    MetricAdapter adapter;

    address recipient = address(0xDEAD);

    function setUp() public {
        wmon = new MockERC20();
        usdc = new MockERC20();
        pool = new MockMetricPool(address(wmon), address(usdc));
        router = new MockMetricRouter();
        // H1: the test contract stands in for NullRouter, and the pool must be on the
        // construction-time allowlist (Metric exposes no factory getPool view on Monad).
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        adapter = new MetricAdapter(address(this), address(router), pools);

        // Venue inventory on the router (it pays recipients from its own balance).
        wmon.mint(address(router), 1_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    // 1. Full fill token0 -> token1 (zeroForOne derived on-chain from getImmutables).
    function test_swap_fullFill_zeroForOne() public {
        router.setRate(2e6); // 2 USDC per 1 WMON
        uint256 amountIn = 2e18;
        wmon.mint(address(adapter), amountIn); // PUSH model

        uint256 amountOut =
            adapter.swap(address(wmon), address(usdc), amountIn, recipient, abi.encode(address(pool)));

        assertEq(amountOut, 4e6, "amountOut");
        assertEq(usdc.balanceOf(recipient), 4e6, "output forwarded");
        assertEq(wmon.balanceOf(address(adapter)), 0, "no input stuck");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no output stuck");
        assertEq(wmon.allowance(address(adapter), address(router)), 0, "approval reset");
    }

    // 2. Full fill token1 -> token0 (reverse direction, price-limit sentinel = uint128.max).
    function test_swap_fullFill_oneForZero() public {
        router.setRate(0.5e30); // 0.5 WMON per 1 USDC (6-dec in, 18-dec out)
        uint256 amountIn = 4e6;
        usdc.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(usdc), address(wmon), amountIn, recipient, abi.encode(address(pool)));

        assertEq(amountOut, 2e18, "amountOut");
        assertEq(wmon.balanceOf(recipient), 2e18, "output forwarded");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no input stuck");
        assertEq(wmon.balanceOf(address(adapter)), 0, "no output stuck");
        assertEq(usdc.allowance(address(adapter), address(router)), 0, "approval reset");
    }

    // 3. Partial fill: router consumes only amountInUsed; remainder forwarded to `to`.
    function test_swap_partialFill() public {
        router.setRate(2e6);
        router.setUseRatio(0.6e18); // consumes 60%
        uint256 amountIn = 2e18;
        wmon.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(wmon), address(usdc), amountIn, recipient, abi.encode(address(pool)));

        // used = 1.2e18 -> out = 2.4e6; leftover 0.8e18 returned to `to`
        assertEq(amountOut, 2.4e6, "out for the used part only");
        assertEq(usdc.balanceOf(recipient), 2.4e6, "output forwarded");
        assertEq(wmon.balanceOf(recipient), 0.8e18, "unused input returned to `to`");
        assertEq(wmon.balanceOf(address(adapter)), 0, "zero input balance");
        assertEq(usdc.balanceOf(address(adapter)), 0, "zero output balance");
        assertEq(wmon.allowance(address(adapter), address(router)), 0, "approval reset");
    }

    // 4. No-fill: router returns (0,0) without reverting -> adapter must revert METRIC_NO_FILL.
    function test_swap_noFill_reverts() public {
        router.setNoFill(true);
        wmon.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("METRIC_NO_FILL"));
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(pool)));
    }

    // 5. Token not in the pool's pair -> METRIC_PAIR_MISMATCH.
    function test_pairMismatch_reverts() public {
        MockERC20 other = new MockERC20();
        other.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("METRIC_PAIR_MISMATCH"));
        adapter.swap(address(other), address(usdc), 1e18, recipient, abi.encode(address(pool)));

        // tokenIn matches token0 but tokenOut is not token1 -> still a mismatch.
        wmon.mint(address(adapter), 1e18);
        vm.expectRevert(bytes("METRIC_PAIR_MISMATCH"));
        adapter.swap(address(wmon), address(wmon), 1e18, recipient, abi.encode(address(pool)));
    }

    // 6. Safe-cast guard: amountIn above uint128 must revert, never truncate.
    function test_overflow_reverts() public {
        uint256 amountIn = uint256(type(uint128).max) + 1;

        vm.expectRevert(bytes("METRIC_OVERFLOW"));
        adapter.swap(address(wmon), address(usdc), amountIn, recipient, abi.encode(address(pool)));
    }

    // 7. PUSH model: swap() without pre-funding must revert (router pull fails on balance).
    function test_notPrefunded_reverts() public {
        router.setRate(2e6);

        vm.expectRevert();
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(pool)));
    }
}
