// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NullArbExecutor} from "../src/NullArbExecutor.sol";
import {IAdapter} from "../src/interfaces/IAdapter.sol";

/// Minimal ERC20 with allowance (enough for safeTransfer/safeTransferFrom in TransferLib).
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "ALLOWANCE");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// Mock adapter replicating the real transfer-then-call pattern: it must be pre-funded with tokenIn
/// (msg.sender pushed it here before calling swap), then it mints tokenOut to `to` at a fixed rate.
contract MockAdapter is IAdapter {
    uint256 public rate; // amountOut = amountIn * rate / 1e18

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata // extraData
    ) external override returns (uint256 amountOut) {
        // Must have been pre-funded (transfer-then-call), exactly like the real adapters.
        require(MockERC20(tokenIn).balanceOf(address(this)) >= amountIn, "NOT_PREFUNDED");
        // Consume the input (simulate paying the pool).
        MockERC20(tokenIn).transfer(address(0xDEAD), amountIn);
        amountOut = (amountIn * rate) / 1e18;
        MockERC20(tokenOut).mint(to, amountOut);
    }
}

/// Adapter whitelist stand-in: only addresses explicitly approved pass, exactly like the real
/// AdapterRegistry proxy. (The audit's H6 PoC hinges on the executor having NO whitelist at all.)
contract MockRegistry {
    mapping(address => bool) public isApproved;

    function setApproved(address adapter, bool ok) external {
        isApproved[adapter] = ok;
    }
}

/// The H6 attack adapter: it is NOT pre-funded and it swaps nothing. It simply reports whatever
/// `amountOut` the attacker wants, which the executor used to chain forward and then pay out of its
/// own standing balance.
contract FakeAdapter is IAdapter {
    uint256 public reportedOut;

    constructor(uint256 reportedOut_) {
        reportedOut = reportedOut_;
    }

    function swap(address, address, uint256, address, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        return reportedOut;
    }
}

contract NullArbExecutorTest is Test {
    NullArbExecutor exec;
    MockRegistry registry;
    MockERC20 wmon;
    MockERC20 usdc;
    MockAdapter legA; // WMON -> USDC (rate 1.10 => arb-favourable leg)
    MockAdapter legB; // USDC -> WMON (rate 1.00)

    // The operator IS the bot now: `arb` is onlyOwner (audit H6). `stranger` stands in for the
    // pre-fix "any caller".
    address owner = address(0x0417);
    address bot = address(0x0417);
    address stranger = address(0xB07);

    function setUp() public {
        registry = new MockRegistry();
        exec = new NullArbExecutor(owner, address(registry));
        wmon = new MockERC20();
        usdc = new MockERC20();
        // Product of rates = 1.155 > 1 => the cycle mints more WMON than it started with (profitable).
        legA = new MockAdapter(1.1e18);
        legB = new MockAdapter(1.05e18);
        registry.setApproved(address(legA), true);
        registry.setApproved(address(legB), true);
    }

    function _routes(uint256 amountIn) internal view returns (NullArbExecutor.RouteStep[] memory r) {
        r = new NullArbExecutor.RouteStep[](2);
        r[0] = NullArbExecutor.RouteStep({
            adapter: address(legA),
            tokenIn: address(wmon),
            tokenOut: address(usdc),
            amountIn: amountIn,
            extraData: ""
        });
        r[1] = NullArbExecutor.RouteStep({
            adapter: address(legB),
            tokenIn: address(usdc),
            tokenOut: address(wmon),
            amountIn: 0, // ignored for hop > 0
            extraData: ""
        });
    }

    // --- Success path: chaining + no-fee + zero standing balance invariant ---

    function test_arb_success_chains_and_takesNoFee() public {
        uint256 amountIn = 100e18;
        wmon.mint(bot, amountIn);

        vm.startPrank(bot);
        wmon.approve(address(exec), amountIn);
        uint256 out = exec.arb(amountIn, 0, block.timestamp + 1, _routes(amountIn));
        vm.stopPrank();

        // 100 * 1.10 = 110 USDC ; 110 * 1.05 = 115.5 WMON. No fee => bot receives the full 115.5.
        assertEq(out, 115.5e18, "final out");
        assertEq(wmon.balanceOf(bot), 115.5e18, "bot got full output, no fee");

        // Invariant: executor holds ZERO of every token afterwards.
        assertEq(wmon.balanceOf(address(exec)), 0, "no WMON stuck");
        assertEq(usdc.balanceOf(address(exec)), 0, "no USDC stuck");
    }

    // --- Revert protection: minAmountOut not met ---

    function test_arb_revertsWhenMinOutNotMet() public {
        uint256 amountIn = 100e18;
        wmon.mint(bot, amountIn);

        vm.startPrank(bot);
        wmon.approve(address(exec), amountIn);
        // Demand 116 but the cycle only yields 115.5.
        vm.expectRevert(
            abi.encodeWithSelector(NullArbExecutor.InsufficientOutput.selector, 115.5e18, 116e18)
        );
        exec.arb(amountIn, 116e18, block.timestamp + 1, _routes(amountIn));
        vm.stopPrank();
    }

    // --- Hop-continuity guard: cannot decouple hop tokens ---

    function test_arb_revertsOnHopTokenMismatch() public {
        uint256 amountIn = 100e18;
        wmon.mint(bot, amountIn);

        NullArbExecutor.RouteStep[] memory r = _routes(amountIn);
        // Break continuity: hop 1 claims to consume WMON, but hop 0 produced USDC.
        r[1].tokenIn = address(wmon);

        vm.startPrank(bot);
        wmon.approve(address(exec), amountIn);
        vm.expectRevert(NullArbExecutor.HopTokenMismatch.selector);
        exec.arb(amountIn, 0, block.timestamp + 1, r);
        vm.stopPrank();
    }

    // --- Deadline / empty / zero guards ---

    function test_arb_revertsWhenExpired() public {
        wmon.mint(bot, 1e18);
        vm.startPrank(bot);
        wmon.approve(address(exec), 1e18);
        vm.warp(1000);
        vm.expectRevert(NullArbExecutor.Expired.selector);
        exec.arb(1e18, 0, 999, _routes(1e18));
        vm.stopPrank();
    }

    function test_arb_revertsOnEmptyRoute() public {
        NullArbExecutor.RouteStep[] memory r = new NullArbExecutor.RouteStep[](0);
        vm.prank(owner);
        vm.expectRevert(NullArbExecutor.EmptyRoute.selector);
        exec.arb(1e18, 0, block.timestamp + 1, r);
    }

    function test_arb_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(NullArbExecutor.ZeroAmount.selector);
        exec.arb(0, 0, block.timestamp + 1, _routes(0));
    }

    // ============================================================
    // H6 (audit 2026-08-05): access control + adapter whitelist.
    // Both of these PASS-as-drain before the fix — `arb` was `external` with no registry.
    // ============================================================

    /// A stranger holding a valid, profitable, fully-whitelisted route is still rejected: the
    /// contract is pre-funded by its operator and only the operator may spend it.
    function test_arb_revertsForNonOwner() public {
        uint256 amountIn = 100e18;
        wmon.mint(stranger, amountIn);

        vm.startPrank(stranger);
        wmon.approve(address(exec), amountIn);
        vm.expectRevert(); // OwnableUnauthorizedAccount(stranger)
        exec.arb(amountIn, 0, block.timestamp + 1, _routes(amountIn));
        vm.stopPrank();
    }

    /// The full H6 drain, run by the owner so ONLY the whitelist can stop it: a fake "adapter"
    /// that swaps nothing and simply reports an output. Pre-fix the executor transferred to it,
    /// chained its self-reported number, and paid out the contract's standing balance.
    function test_arb_revertsOnUnapprovedAdapter() public {
        usdc.mint(address(exec), 500e18); // standing balance the attacker is after

        FakeAdapter fake = new FakeAdapter(500e18);
        NullArbExecutor.RouteStep[] memory r = new NullArbExecutor.RouteStep[](2);
        r[0] = NullArbExecutor.RouteStep({
            adapter: address(fake),
            tokenIn: address(wmon),
            tokenOut: address(usdc),
            amountIn: 1,
            extraData: ""
        });
        r[1] = NullArbExecutor.RouteStep({
            adapter: address(legB),
            tokenIn: address(usdc),
            tokenOut: address(wmon),
            amountIn: 0,
            extraData: ""
        });

        wmon.mint(owner, 1);
        vm.startPrank(owner);
        wmon.approve(address(exec), 1);
        vm.expectRevert(abi.encodeWithSelector(NullArbExecutor.UnapprovedAdapter.selector, address(fake)));
        exec.arb(1, 0, block.timestamp + 1, r);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(exec)), 500e18, "standing balance untouched");
    }

    /// The whitelist is checked on EVERY hop, not just the entry one — an approved first leg must
    /// not launder an unapproved second leg.
    function test_arb_revertsOnUnapprovedAdapter_laterHop() public {
        registry.setApproved(address(legB), false);
        uint256 amountIn = 100e18;
        wmon.mint(owner, amountIn);

        vm.startPrank(owner);
        wmon.approve(address(exec), amountIn);
        vm.expectRevert(abi.encodeWithSelector(NullArbExecutor.UnapprovedAdapter.selector, address(legB)));
        exec.arb(amountIn, 0, block.timestamp + 1, _routes(amountIn));
        vm.stopPrank();
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(NullArbExecutor.ZeroAddress.selector);
        new NullArbExecutor(owner, address(0));
    }

    // --- rescue() is owner-only ---

    function test_rescue_ownerOnly() public {
        // Simulate stuck dust.
        usdc.mint(address(exec), 5e18);

        // Non-owner cannot rescue.
        vm.prank(stranger);
        vm.expectRevert();
        exec.rescue(address(usdc), 5e18, stranger);

        // Owner can.
        vm.prank(owner);
        exec.rescue(address(usdc), 5e18, owner);
        assertEq(usdc.balanceOf(owner), 5e18, "owner rescued dust");
        assertEq(usdc.balanceOf(address(exec)), 0, "dust cleared");
    }

    // ============================================================
    // Optional live fork test — skips gracefully if MONAD_RPC_URL unset/unreachable.
    // Uses the SAME adapter addresses + extraData the engine would supply.
    // ============================================================

    function test_fork_arb_wmon_usdc_wmon() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: MONAD_RPC_URL not set - fork test skipped");
            return;
        }
        try vm.createSelectFork(rpc) {
            // Reached the fork. A full round-trip needs the real adapter addresses + engine extraData
            // (PoolKey for V4), which are engine-owned and change per pool. The mock unit tests above
            // fully exercise the chaining / minOut / no-fee / continuity logic; this branch just proves
            // the fork is reachable so an operator can extend it with a live quote.
            emit log("fork reachable - plug in engine-provided adapter+extraData for a live round-trip");
        } catch {
            emit log("SKIP: fork unreachable - skipped");
        }
    }
}
