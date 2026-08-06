// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The feeManager role exists so the fee-churn keeper can run WITHOUT the owner key — that
///         key also authorises `_authorizeUpgrade` on the router, so hosting it on a shared box
///         would turn any host compromise into total protocol control. These tests pin the exact
///         boundary: per-token overrides yes, everything else no.
contract FeeManagerRoleTest is Test {
    FeeCollector fc;
    address owner = address(0xA11CE);
    address manager = address(0xBEEF);
    address stranger = address(0xBAD);
    address treasury = address(0x7);
    address router = address(0x8);
    address tokenA = address(0x1111);

    function setUp() public {
        FeeCollector impl = new FeeCollector();
        bytes memory init =
            abi.encodeCall(FeeCollector.initialize, (owner, treasury, router, 50, 5000));
        fc = FeeCollector(address(new ERC1967Proxy(address(impl), init)));
    }

    function test_defaultsToNoManager() public view {
        assertEq(fc.feeManager(), address(0));
    }

    function test_ownerCanStillSetOverrides_withNoManager() public {
        vm.prank(owner);
        fc.setTokenFeeBps(tokenA, 25);
        assertEq(fc.feeBpsFor(tokenA), 25);
    }

    function test_managerCanSetClearAndBatch() public {
        vm.prank(owner);
        fc.setFeeManager(manager);

        vm.prank(manager);
        fc.setTokenFeeBps(tokenA, 25);
        assertEq(fc.feeBpsFor(tokenA), 25);

        address[] memory toks = new address[](1);
        uint16[] memory bps = new uint16[](1);
        toks[0] = tokenA;
        bps[0] = 15;
        vm.prank(manager);
        fc.setTokenFeeBpsBatch(toks, bps);
        assertEq(fc.feeBpsFor(tokenA), 15);

        vm.prank(manager);
        fc.clearTokenFeeBps(tokenA);
        assertEq(fc.feeBpsFor(tokenA), 50); // back to the global default
    }

    /// The whole point of the role: a stolen manager key must not reach anything but per-token bps.
    function test_managerCannotTouchOwnerSurface() public {
        vm.prank(owner);
        fc.setFeeManager(manager);
        // Hoisted: any call/CREATE evaluated inside an argument list would be the call
        // `vm.expectRevert` watches, silently passing the test for the wrong reason.
        address newImpl = address(new FeeCollector());

        vm.prank(manager);
        vm.expectRevert();
        fc.setFeeBps(100); // global default stays owner-only

        vm.prank(manager);
        vm.expectRevert();
        fc.withdrawFees(tokenA, manager);

        vm.prank(manager);
        vm.expectRevert();
        fc.setTreasury(manager);

        vm.prank(manager);
        vm.expectRevert();
        fc.setRouter(manager);

        vm.prank(manager);
        vm.expectRevert();
        fc.setReferralShareBps(0);

        vm.prank(manager);
        vm.expectRevert();
        fc.setFeeManager(stranger); // cannot grant itself company

        vm.prank(manager);
        vm.expectRevert();
        fc.upgradeToAndCall(newImpl, "");
    }

    /// Even inside its own lane the manager is bounded by the 1% ceiling.
    function test_managerStillBoundedByCap() public {
        vm.prank(owner);
        fc.setFeeManager(manager);
        uint16 overCap = fc.MAX_FEE_BPS() + 1; // hoisted — see note above
        vm.prank(manager);
        vm.expectRevert(bytes("FEE_TOO_HIGH"));
        fc.setTokenFeeBps(tokenA, overCap);
    }

    function test_strangerRejectedBeforeAndAfterGrant() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotFeeAdmin.selector);
        fc.setTokenFeeBps(tokenA, 25);

        vm.prank(owner);
        fc.setFeeManager(manager);

        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotFeeAdmin.selector);
        fc.setTokenFeeBps(tokenA, 25);
    }

    function test_revokeRestoresOwnerOnly() public {
        vm.prank(owner);
        fc.setFeeManager(manager);
        vm.prank(manager);
        fc.setTokenFeeBps(tokenA, 25);

        vm.prank(owner);
        fc.setFeeManager(address(0)); // revoke

        vm.prank(manager);
        vm.expectRevert(FeeCollector.NotFeeAdmin.selector);
        fc.setTokenFeeBps(tokenA, 0);

        vm.prank(owner);
        fc.setTokenFeeBps(tokenA, 0); // owner unaffected
        assertEq(fc.feeBpsFor(tokenA), 0);
    }

    /// address(0) must never be treated as "the manager" (msg.sender can't be 0, but the guard is
    /// written so a zeroed slot can't widen access by accident).
    function test_zeroManagerDoesNotOpenTheGate() public {
        assertEq(fc.feeManager(), address(0));
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotFeeAdmin.selector);
        fc.clearTokenFeeBps(tokenA);
    }
}
