// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {IFeeCollector} from "../src/interfaces/IFeeCollector.sol";

/// Minimal ERC20 with public mint (test-only).
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _x(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "ALLOWANCE"); allowance[f][msg.sender] = al - a; }
        _x(f, to, a); return true;
    }
    function _x(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

/// A token whose `transfer` re-enters `collectFee`. It is deployed AS the collector's router so it
/// passes `onlyRouter` — the shape a hostile referral-token would need. Models the INFO finding:
/// `collectFee` used to pay the referrer (an external call to a caller-supplied address) BEFORE
/// crediting the treasury, with no reentrancy guard.
contract ReenterToken {
    mapping(address => uint256) public balanceOf;
    FeeCollector public fc;
    bool public entered;
    bool public reenterSucceeded;

    function setFc(FeeCollector f) external { fc = f; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "BAL");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (!entered) {
            entered = true;
            // Re-enter with no referrer → the whole amount would be booked a SECOND time.
            (bool ok, ) = address(fc).call(
                abi.encodeWithSelector(FeeCollector.collectFee.selector, address(this), a, address(0))
            );
            reenterSucceeded = ok;
        }
        return true;
    }
}

/// Unit tests for the tiered per-token fee added to FeeCollector.
contract FeeCollectorTest is Test {
    FeeCollector fc;
    MockERC20 tok;
    address owner = address(this);
    address router = makeAddr("router");
    address treasury = address(0x7);
    address tokenX = address(0xA11);
    address tokenY = address(0xB22);
    address notOwner = address(0xBAD);

    function setUp() public {
        FeeCollector impl = new FeeCollector();
        bytes memory initData = abi.encodeCall(
            FeeCollector.initialize,
            (owner, treasury, router, 5, 5000) // 5 bps default, 50% referral share
        );
        fc = FeeCollector(address(new ERC1967Proxy(address(impl), initData)));
        tok = new MockERC20();
    }

    // ── default / override resolution ──────────────────────────────────────────

    function test_default_noOverride_returnsGlobal() public view {
        assertEq(fc.feeBpsFor(tokenX), 5, "unset token uses global default");
        assertEq(fc.feeBps(), 5);
    }

    function test_setOverride_appliesPerToken() public {
        fc.setTokenFeeBps(tokenX, 30);
        assertEq(fc.feeBpsFor(tokenX), 30, "override applies");
        assertEq(fc.feeBpsFor(tokenY), 5, "other tokens unaffected");
    }

    function test_explicitZeroOverride_isRespected() public {
        fc.setTokenFeeBps(tokenX, 0);
        assertEq(fc.feeBpsFor(tokenX), 0, "explicit 0bps must resolve to 0, not the default");
    }

    function test_clearOverride_revertsToDefault() public {
        fc.setTokenFeeBps(tokenX, 50);
        assertEq(fc.feeBpsFor(tokenX), 50);
        fc.clearTokenFeeBps(tokenX);
        assertEq(fc.feeBpsFor(tokenX), 5, "cleared token falls back to default");
    }

    function test_changeGlobalDefault_flowsToUnsetTokens() public {
        fc.setFeeBps(3);
        assertEq(fc.feeBpsFor(tokenY), 3, "unset token follows the new global default");
        fc.setTokenFeeBps(tokenX, 30);
        fc.setFeeBps(7);
        assertEq(fc.feeBpsFor(tokenX), 30, "overridden token ignores global changes");
    }

    // ── caps / auth ────────────────────────────────────────────────────────────

    function test_maxFeeBps_isOnePercent() public view {
        assertEq(fc.MAX_FEE_BPS(), 100);
    }

    function test_setOverride_aboveCap_reverts() public {
        vm.expectRevert(bytes("FEE_TOO_HIGH"));
        fc.setTokenFeeBps(tokenX, 101);
    }

    function test_setOverride_atCap_ok() public {
        fc.setTokenFeeBps(tokenX, 100);
        assertEq(fc.feeBpsFor(tokenX), 100);
    }

    function test_setOverride_nonOwner_reverts() public {
        vm.prank(notOwner);
        vm.expectRevert();
        fc.setTokenFeeBps(tokenX, 30);
    }

    function test_clearOverride_nonOwner_reverts() public {
        fc.setTokenFeeBps(tokenX, 30);
        vm.prank(notOwner);
        vm.expectRevert();
        fc.clearTokenFeeBps(tokenX);
    }

    // ── batch ──────────────────────────────────────────────────────────────────

    function test_batch_setsAll() public {
        address[] memory toks = new address[](2);
        uint16[] memory bps = new uint16[](2);
        toks[0] = tokenX; toks[1] = tokenY;
        bps[0] = 30; bps[1] = 50;
        fc.setTokenFeeBpsBatch(toks, bps);
        assertEq(fc.feeBpsFor(tokenX), 30);
        assertEq(fc.feeBpsFor(tokenY), 50);
    }

    function test_batch_lengthMismatch_reverts() public {
        address[] memory toks = new address[](2);
        uint16[] memory bps = new uint16[](1);
        toks[0] = tokenX; toks[1] = tokenY;
        bps[0] = 30;
        vm.expectRevert(bytes("LENGTH_MISMATCH"));
        fc.setTokenFeeBpsBatch(toks, bps);
    }

    function test_batch_anyAboveCap_reverts() public {
        address[] memory toks = new address[](2);
        uint16[] memory bps = new uint16[](2);
        toks[0] = tokenX; toks[1] = tokenY;
        bps[0] = 30; bps[1] = 200; // second exceeds cap
        vm.expectRevert(bytes("FEE_TOO_HIGH"));
        fc.setTokenFeeBpsBatch(toks, bps);
    }

    // ── referral split still correct on a tiered fee ────────────────────────────

    function test_collectFee_referralSplit_unchanged() public {
        // Router pushes the fee token to the collector, then calls collectFee (onlyRouter).
        address referrer = makeAddr("referrer");
        tok.mint(address(fc), 1000);
        vm.prank(router);
        fc.collectFee(address(tok), 1000, referrer);
        assertEq(tok.balanceOf(referrer), 500, "referrer gets 50%");
        assertEq(fc.accumulatedFees(address(tok)), 500, "treasury accrues 50%");
    }

    function test_collectFee_noReferrer_allToTreasury() public {
        tok.mint(address(fc), 1000);
        vm.prank(router);
        fc.collectFee(address(tok), 1000, address(0));
        assertEq(fc.accumulatedFees(address(tok)), 1000, "100% to treasury when no referrer");
    }

    function test_collectFee_onlyRouter() public {
        vm.expectRevert(FeeCollector.OnlyRouter.selector);
        fc.collectFee(address(tok), 1000, address(0));
    }

    // ── L1: recovering balance the fee ledger never booked ──────────────────────
    // withdrawFees pays out of `accumulatedFees`, so anything that arrives unbooked used to be
    // unrecoverable without a UUPS upgrade. That happened for real: a swap naming the collector as
    // its own referrer made the referral transfer a self-transfer the ledger never credited.

    function test_sweepUnaccounted_movesOnlyTheUnledgeredBalance() public {
        tok.mint(address(fc), 1000);
        vm.prank(router);
        fc.collectFee(address(tok), 1000, address(0)); // 1000 booked, 1000 held
        tok.mint(address(fc), 400);                    // arrives unbooked

        fc.sweepUnaccounted(address(tok), treasury);

        assertEq(tok.balanceOf(treasury), 400, "only the unaccounted balance leaves");
        assertEq(fc.accumulatedFees(address(tok)), 1000, "ledger untouched");
        assertEq(tok.balanceOf(address(fc)), 1000, "collector still fully covers what it owes");
    }

    function test_sweepUnaccounted_cannotTouchBookedFees() public {
        tok.mint(address(fc), 1000);
        vm.prank(router);
        fc.collectFee(address(tok), 1000, address(0));

        // Balance == ledger → there is nothing to sweep, and treasury's withdrawal still works.
        vm.expectRevert(bytes("NOTHING_UNACCOUNTED"));
        fc.sweepUnaccounted(address(tok), treasury);

        fc.withdrawFees(address(tok), treasury);
        assertEq(tok.balanceOf(treasury), 1000, "withdrawFees unaffected");
    }

    function test_sweepUnaccounted_authAndZeroAddress() public {
        tok.mint(address(fc), 100);
        vm.prank(notOwner);
        vm.expectRevert();
        fc.sweepUnaccounted(address(tok), notOwner);

        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.sweepUnaccounted(address(tok), address(0));
    }

    // ── INFO: checks-effects-interactions + reentrancy guard on collectFee ──────
    function test_collectFee_reentrantReferralTokenCannotDoubleBook() public {
        ReenterToken rtok = new ReenterToken();
        FeeCollector impl = new FeeCollector();
        FeeCollector fc2 = FeeCollector(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeCollector.initialize, (owner, treasury, address(rtok), 5, 5000))
        )));
        rtok.setFc(fc2);
        rtok.mint(address(fc2), 1000);

        address referrer = makeAddr("referrer");
        vm.prank(address(rtok)); // the token IS the router here, so onlyRouter cannot save us
        fc2.collectFee(address(rtok), 1000, referrer);

        assertFalse(rtok.reenterSucceeded(), "the re-entrant collectFee must be rejected");
        assertEq(fc2.accumulatedFees(address(rtok)), 500, "treasury credited exactly once");
        assertEq(rtok.balanceOf(referrer), 500, "referrer paid exactly once");
    }
}
