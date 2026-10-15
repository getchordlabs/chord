// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RhStockZap} from "../src/RhStockZap.sol";
import {NullExecutor} from "../src/NullExecutor.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

// ROUND 13 (G6/G7) — the last two fund-touching contracts without a test file.

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// A non-reverting `false` return — the exact shape L8 says must never be discarded.
    bool public transferReturnsFalse;

    function setTransferReturnsFalse(bool v) external { transferReturnsFalse = v; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (transferReturnsFalse) return false;
        _x(msg.sender, to, a); return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "ALLOWANCE"); allowance[f][msg.sender] = al - a; }
        _x(f, to, a); return true;
    }
    function _x(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

/// Records what it was asked to swap so the test can assert the FULL bridged amount was used.
contract MockV3Router {
    uint256 public lastAmountIn;
    uint256 public lastMinOut;
    address public lastRecipient;
    bool public shouldRevert;
    MockERC20 public stock;

    constructor(MockERC20 s) { stock = s; }
    function setRevert(bool v) external { shouldRevert = v; }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256) {
        if (shouldRevert) revert("pool blew up");
        lastAmountIn = p.amountIn;
        lastMinOut = p.amountOutMinimum;
        lastRecipient = p.recipient;
        MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        stock.mint(p.recipient, p.amountIn * 2); // arbitrary rate
        return p.amountIn * 2;
    }
}

contract RhStockZapTest is Test {
    MockERC20 usdg;
    MockERC20 stock;
    MockV3Router v3;
    RhStockZap zap;
    address buyer = address(0xB0B);
    address bridge = address(0xB41D6E); // whoever holds the bridged USDG and calls zapFrom

    function setUp() public {
        usdg = new MockERC20();
        stock = new MockERC20();
        v3 = new MockV3Router(stock);
        zap = new RhStockZap(address(usdg), address(v3));
    }

    function _fund(uint256 amount) internal {
        usdg.mint(bridge, amount);
        vm.prank(bridge);
        usdg.approve(address(zap), type(uint256).max);
    }

    // G7 — the bug this contract was born from: hardcoding amountIn instead of pulling the balance.
    // Relay's bridged amount is only known at execution time (fees are taken en route), so any
    // fixed number is either short (leftover stranded) or too large (TRANSFER_FROM_FAILED). With
    // H5's `maxIn` the pull is min(balance, maxIn) — a generous ceiling still consumes what arrived.
    function testFuzz_zapAlwaysSwapsTheFullBridgedBalance(uint128 rawBridged) public {
        uint256 bridged = bound(uint256(rawBridged), 1, type(uint96).max);
        _fund(bridged);

        vm.prank(bridge);
        zap.zapFrom(address(stock), 3000, buyer, 0, type(uint96).max);

        assertEq(v3.lastAmountIn(), bridged, "the swap must use exactly what arrived, never a hardcoded amount");
        assertEq(v3.lastRecipient(), buyer, "the stock must go to the buyer, not the zap");
        assertEq(usdg.balanceOf(address(zap)), 0, "the zap must hold nothing between calls");
        assertEq(usdg.balanceOf(bridge), 0, "the whole bridged balance is consumed");
    }

    // ── H5: the pull is BOUNDED by maxIn, never the caller's entire balance ──
    // The Relay call-executor can be shared across fills. Before this, an attacker submitted their
    // own tiny order with buyer = ATTACKER, timed so the executor also held a victim's bridged USDG,
    // and walked off with all of it — a bogus fee tier even made the swap revert into the catch,
    // which handed them the raw USDG with no pool needed.
    function test_zapPullsOnlyMaxInAndLeavesTheRestForItsOwner() public {
        uint256 victimFunds = 10_000e6;
        uint256 attackerOrder = 100e6;
        _fund(victimFunds + attackerOrder); // shared executor holds BOTH

        address attacker = address(0xA77ACC);
        vm.prank(bridge);
        zap.zapFrom(address(stock), 3000, attacker, 0, attackerOrder);

        assertEq(v3.lastAmountIn(), attackerOrder, "only the caller's own bridged size may be pulled");
        assertEq(usdg.balanceOf(bridge), victimFunds, "the other fill's funds must be untouched");
        assertEq(usdg.balanceOf(address(zap)), 0, "the zap must hold nothing between calls");
    }

    // The same bound protects the REFUND path, which is the one that needs no working pool at all.
    function test_aFailedSwapRefundsOnlyMaxInNotTheWholeExecutorBalance() public {
        _fund(10_100e6);
        v3.setRevert(true);

        address attacker = address(0xA77ACC);
        vm.prank(bridge);
        zap.zapFrom(address(stock), 3000, attacker, 0, 100e6);

        assertEq(usdg.balanceOf(attacker), 100e6, "the refund is capped at what this call pulled");
        assertEq(usdg.balanceOf(bridge), 10_000e6, "everything else stays with its owner");
    }

    // L8: SwapRouter02 remaps a zero recipient to itself, where a permissionless sweepToken exists.
    function test_zeroBuyerIsRejected() public {
        _fund(1_000e6);
        vm.prank(bridge);
        vm.expectRevert(RhStockZap.BadBuyer.selector);
        zap.zapFrom(address(stock), 3000, address(0), 0, 1_000e6);
    }

    function test_zeroMaxInIsRejected() public {
        _fund(1_000e6);
        vm.prank(bridge);
        vm.expectRevert(RhStockZap.BadMaxIn.selector);
        zap.zapFrom(address(stock), 3000, buyer, 0, 0);
    }

    function test_emptyBalanceReverts() public {
        vm.prank(bridge);
        vm.expectRevert(RhStockZap.NoBalance.selector);
        zap.zapFrom(address(stock), 3000, buyer, 0, 1_000e6);
    }

    function test_aFailedSwapReturnsTheUsdgToTheBuyerNotTheCaller() public {
        // The documented fallback: if the pool cannot fill, the buyer must end up with the USDG so
        // the gasless flow can finish the trade. Stranding it in the zap would let a LATER buyer
        // sweep it (the zap pulls whatever the caller holds).
        _fund(1_000e6);
        v3.setRevert(true);

        vm.prank(bridge);
        zap.zapFrom(address(stock), 3000, buyer, 0, 1_000e6);

        assertEq(usdg.balanceOf(buyer), 1_000e6, "a failed swap must hand the USDG to the buyer");
        assertEq(usdg.balanceOf(address(zap)), 0, "nothing may be left for a later caller to sweep");
        assertEq(stock.balanceOf(buyer), 0);
    }

    // L8: the refund used a raw `transfer` whose return value was discarded, in a contract with no
    // rescue, no owner and no upgrade — a `false` return stranded the user's whole bridged amount
    // forever while ZapReturned claimed success. SafeERC20 makes that revert instead.
    function test_aRefundThatSilentlyFailsMustRevertNotEmitSuccess() public {
        _fund(1_000e6);
        v3.setRevert(true);
        usdg.setTransferReturnsFalse(true);

        vm.prank(bridge);
        vm.expectRevert();
        zap.zapFrom(address(stock), 3000, buyer, 0, 1_000e6);
    }

    function test_minOutIsForwardedToThePool() public {
        _fund(500e6);
        vm.prank(bridge);
        zap.zapFrom(address(stock), 500, buyer, 12345, 500e6);
        assertEq(v3.lastMinOut(), 12345, "the buyer's accepted slippage floor must reach the pool");
    }
}

// ── G6: NullExecutor is delegatecalled by the router, but it is also a live address ──
contract NullExecutorDirectCallTest is Test {
    NullExecutor executor;
    AdapterRegistry registry;
    MockERC20 tA;
    MockERC20 tB;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        AdapterRegistry impl = new AdapterRegistry();
        registry = AdapterRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(AdapterRegistry.initialize, (address(this)))))
        );
        // L9: the registry is pinned at construction now, so it must exist before the executor.
        executor = new NullExecutor(address(registry));
    }

    function test_directCallStillEnforcesTheWhitelist() public {
        // Anyone can call the deployed executor directly rather than through the router. The
        // registry check must not depend on being reached via delegatecall.
        address rogue = address(0xBAD);
        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: rogue,
            tokenIn: address(tA),
            tokenOut: address(tB),
            amountIn: 1 ether,
            extraData: ""
        });
        vm.expectRevert(abi.encodeWithSelector(NullExecutor.UnapprovedAdapter.selector, rogue));
        executor.executeSingle(step, registry);
    }
}
