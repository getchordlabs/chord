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
}
