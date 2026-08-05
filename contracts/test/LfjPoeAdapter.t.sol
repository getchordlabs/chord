// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LfjPoeAdapter} from "../src/adapters/LfjPoeAdapter.sol";

/// Minimal ERC20 — the POE pool never uses allowances (callback PUSH settlement), but transfer
/// semantics must be real so balance checks bite.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface IPoeCallback {
    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata data) external returns (bytes4);
}

/// Mimics the LFJ POE OraclePool semantics the adapter depends on:
/// - getTokens() exposes (tokenX, tokenY).
/// - swap(): sends the OUTPUT to `recipient` FIRST, then calls swapCallback on msg.sender with
///   pool-perspective signed deltas (positive = pool receives), then verifies it was paid exactly
///   the positive delta (underpay reverts Callback__InsufficientTokenReceived) and that the
///   callback returned the magic 0xfa483e72. NO transferFrom anywhere.
/// - Configurable partial fill (actualIn = amountIn * fillRatio) and a no-fill mode that returns
///   (0,0) without output and without invoking the callback.
contract MockPoePool {
    address public tokenX;
    address public tokenY;
    uint256 public rate; // out = actualIn * rate / 1e18
    uint256 public fillRatio = 1e18;
    bool public noFill;

    constructor(address tokenX_, address tokenY_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setFillRatio(uint256 r) external {
        fillRatio = r;
    }

    function setNoFill(bool v) external {
        noFill = v;
    }

    function getTokens() external view returns (address, address) {
        return (tokenX, tokenY);
    }

    function swap(
        address recipient,
        bool swapXtoY,
        uint256 amountIn,
        bytes calldata data
    ) external returns (int256 deltaX, int256 deltaY) {
        if (noFill) return (0, 0);

        uint256 actualIn = (amountIn * fillRatio) / 1e18;
        uint256 out = (actualIn * rate) / 1e18;
        (address tin, address tout) = swapXtoY ? (tokenX, tokenY) : (tokenY, tokenX);

        // Pool-perspective deltas: positive = pool receives.
        if (swapXtoY) {
            deltaX = int256(actualIn);
            deltaY = -int256(out);
        } else {
            deltaY = int256(actualIn);
            deltaX = -int256(out);
        }

        // Output FIRST...
        require(MockERC20(tout).transfer(recipient, out), "PAY");

        // ...then the callback must PUSH the input; balance-check like the real pool.
        uint256 beforeBal = MockERC20(tin).balanceOf(address(this));
        bytes4 ret = IPoeCallback(msg.sender).swapCallback(deltaX, deltaY, data);
        require(ret == bytes4(0xfa483e72), "MOCK_BAD_MAGIC");
        require(
            MockERC20(tin).balanceOf(address(this)) - beforeBal >= actualIn,
            "Callback__InsufficientTokenReceived"
        );
    }
}

/// A contract that is NOT the active pool trying to invoke the adapter's callback mid-swap.
contract EvilCaller {
    function attack(address adapter) external {
        IPoeCallback(adapter).swapCallback(int256(1e18), -int256(1), "");
    }
}

/// A "pool" that hijacks the swap: instead of settling itself, it has an accomplice contract call
/// the adapter's swapCallback DURING the active swap (msg.sender != the tstore'd pool).
contract MockHijackPool {
    address public tokenX;
    address public tokenY;
    EvilCaller public evil;

    constructor(address tokenX_, address tokenY_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
        evil = new EvilCaller();
    }

    function getTokens() external view returns (address, address) {
        return (tokenX, tokenY);
    }

    function swap(address, bool, uint256, bytes calldata) external returns (int256, int256) {
        evil.attack(msg.sender); // must revert POE_BAD_CALLBACK inside the adapter
        return (0, 0);
    }
}

contract LfjPoeAdapterTest is Test {
    MockERC20 wmon; // tokenX, 18-dec
    MockERC20 usdc; // tokenY, 6-dec
    MockPoePool pool;
    /// @dev Allowlisted DELIBERATELY: the callback-gate test must still reach the callback path, so
    ///      the hostile-pool check (H1) cannot be what stops it.
    MockHijackPool hijack;
    LfjPoeAdapter adapter;

    address recipient = address(0xDEAD);

    function setUp() public {
        wmon = new MockERC20();
        usdc = new MockERC20();
        pool = new MockPoePool(address(wmon), address(usdc));
        // H1: the test contract stands in for NullRouter (adapters are onlyRouter now), and the pool
        // must be on the construction-time allowlist (POE has no on-chain registry to pin).
        hijack = new MockHijackPool(address(wmon), address(usdc));
        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = address(hijack);
        adapter = new LfjPoeAdapter(address(this), pools);

        // Venue inventory: the pool pays output from its own balance.
        wmon.mint(address(pool), 1_000e18);
        usdc.mint(address(pool), 1_000_000e6);
    }

    // 1. Full fill X -> Y.
    function test_swap_fullFill_XtoY() public {
        pool.setRate(2e6); // 2 USDC per 1 WMON
        uint256 amountIn = 2e18;
        wmon.mint(address(adapter), amountIn); // PUSH model

        uint256 amountOut =
            adapter.swap(address(wmon), address(usdc), amountIn, recipient, abi.encode(address(pool)));

        assertEq(amountOut, 4e6, "amountOut");
        assertEq(usdc.balanceOf(recipient), 4e6, "output forwarded");
        assertEq(wmon.balanceOf(address(adapter)), 0, "no input stuck");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no output stuck");
    }

    // 2. Full fill Y -> X.
    function test_swap_fullFill_YtoX() public {
        pool.setRate(0.5e30); // 0.5 WMON per 1 USDC (6-dec in, 18-dec out)
        uint256 amountIn = 4e6;
        usdc.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(usdc), address(wmon), amountIn, recipient, abi.encode(address(pool)));

        assertEq(amountOut, 2e18, "amountOut");
        assertEq(wmon.balanceOf(recipient), 2e18, "output forwarded");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no input stuck");
        assertEq(wmon.balanceOf(address(adapter)), 0, "no output stuck");
    }

    // 3. Partial fill: callback pays EXACTLY the positive delta (not amountIn); remainder to `to`.
    function test_swap_partialFill() public {
        pool.setRate(2e6);
        pool.setFillRatio(0.75e18); // actualIn = 75% of amountIn
        uint256 amountIn = 2e18;
        wmon.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(wmon), address(usdc), amountIn, recipient, abi.encode(address(pool)));

        // actualIn = 1.5e18 -> out = 3e6; leftover 0.5e18 back to `to`
        assertEq(amountOut, 3e6, "out for the filled part only");
        assertEq(usdc.balanceOf(recipient), 3e6, "output forwarded");
        assertEq(wmon.balanceOf(recipient), 0.5e18, "unfilled remainder returned to `to`");
        // Pool received exactly the positive delta, not amountIn (1000e18 inventory + 1.5e18).
        assertEq(wmon.balanceOf(address(pool)), 1_000e18 + 1.5e18, "pool paid exactly actualIn");
        assertEq(wmon.balanceOf(address(adapter)), 0, "zero input balance");
        assertEq(usdc.balanceOf(address(adapter)), 0, "zero output balance");
    }

    // 4. No-fill: pool returns (0,0) without output -> adapter must revert POE_NO_FILL.
    function test_swap_noFill_reverts() public {
        pool.setNoFill(true);
        wmon.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("POE_NO_FILL"));
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(pool)));
    }

    // 5. Token not in the pool's pair -> POE_PAIR_MISMATCH.
    function test_pairMismatch_reverts() public {
        MockERC20 other = new MockERC20();
        other.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("POE_PAIR_MISMATCH"));
        adapter.swap(address(other), address(usdc), 1e18, recipient, abi.encode(address(pool)));

        // tokenIn matches X but tokenOut is not Y -> still a mismatch.
        wmon.mint(address(adapter), 1e18);
        vm.expectRevert(bytes("POE_PAIR_MISMATCH"));
        adapter.swap(address(wmon), address(wmon), 1e18, recipient, abi.encode(address(pool)));
    }

    // 6a. Callback gating: a stranger calling swapCallback OUTSIDE any swap must revert
    //     (transient slot is zero -> msg.sender can never match).
    function test_callback_directCall_reverts() public {
        vm.expectRevert(bytes("POE_BAD_CALLBACK"));
        adapter.swapCallback(int256(1e18), -int256(1), "");
    }

    // 6b. Callback gating: a DIFFERENT contract calling swapCallback DURING an active swap must
    //     also revert — only the tstore'd pool itself may settle.
    function test_callback_hijack_reverts() public {
        wmon.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("POE_BAD_CALLBACK"));
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(hijack)));
    }

    // 7. PUSH model: swap() without pre-funding must revert (callback transfer fails on balance).
    function test_notPrefunded_reverts() public {
        pool.setRate(2e6);

        vm.expectRevert();
        adapter.swap(address(wmon), address(usdc), 1e18, recipient, abi.encode(address(pool)));
    }
}
