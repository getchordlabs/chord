// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { RhTokenZap } from "../src/RhTokenZap.sol";

contract ZapToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Router stand-in: pulls `amountIn` USDG from msg.sender and mints `payout` of tokenOut to it.
contract ZapRouter {
    ZapToken public usdg;
    uint256 public payout;
    uint256 public consume; // how much USDG the "route" actually pulls
    bool public shouldRevert;
    constructor(ZapToken u) { usdg = u; }
    function set(uint256 p, uint256 c, bool r) external { payout = p; consume = c; shouldRevert = r; }
    function swap(address tokenOut, uint256 amountIn) external {
        if (shouldRevert) revert("route dead");
        usdg.transferFrom(msg.sender, address(this), consume == 0 ? amountIn : consume);
        ZapToken(tokenOut).mint(msg.sender, payout);
    }
}

contract RhTokenZapTest is Test {
    ZapToken usdg;
    ZapToken meme;
    ZapRouter router;
    RhTokenZap zap;
    address solver = address(0x5011);
    address buyer = address(0xB0B);

    function setUp() public {
        usdg = new ZapToken("USDG");
        meme = new ZapToken("MEME");
        router = new ZapRouter(usdg);
        zap = new RhTokenZap(address(usdg), address(router));
        usdg.mint(solver, 100e6); // the solver delivered 100 USDG to itself before calling the zap
        vm.prank(solver);
        usdg.approve(address(zap), type(uint256).max);
    }

    function _data(uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeWithSelector(ZapRouter.swap.selector, address(meme), amountIn);
    }

    function test_zap_deliversToBuyer_capsAtMaxIn() public {
        router.set(500e18, 0, false);
        vm.prank(solver);
        zap.zapFrom(address(meme), buyer, 400e18, 90e6, _data(90e6)); // maxIn 90 of the 100 held
        assertEq(meme.balanceOf(buyer), 500e18, "output to buyer");
        assertEq(usdg.balanceOf(solver), 10e6, "only maxIn pulled");
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(meme.balanceOf(address(zap)), 0);
    }

    function test_zap_spendsBalanceWhenBelowMaxIn_returnsUnconsumed() public {
        router.set(200e18, 60e6, false); // route only consumes 60 of the 100 pulled
        vm.prank(solver);
        zap.zapFrom(address(meme), buyer, 1, 150e6, _data(60e6)); // maxIn above balance → whole balance pulled
        assertEq(meme.balanceOf(buyer), 200e18);
        assertEq(usdg.balanceOf(buyer), 40e6, "unconsumed anchor returned to the buyer");
        assertEq(usdg.balanceOf(solver), 0);
    }

    function test_underDelivery_returnsAnchorAndPartial() public {
        router.set(100e18, 0, false); // below minOut
        vm.prank(solver);
        zap.zapFrom(address(meme), buyer, 400e18, 100e6, _data(100e6));
        assertEq(meme.balanceOf(buyer), 100e18, "partial output still handed over");
        assertEq(usdg.balanceOf(buyer), 0, "route consumed the anchor");
        assertEq(usdg.balanceOf(address(zap)), 0);
    }

    function test_routeRevert_returnsAnchor_neverReverts() public {
        router.set(0, 0, true);
        vm.prank(solver);
        zap.zapFrom(address(meme), buyer, 1, 100e6, _data(100e6));
        assertEq(usdg.balanceOf(buyer), 100e6, "anchor handed to the buyer, not stranded with the solver");
        assertEq(meme.balanceOf(buyer), 0);
    }

    function test_guards() public {
        vm.startPrank(solver);
        vm.expectRevert(RhTokenZap.BadBuyer.selector);
        zap.zapFrom(address(meme), address(0), 1, 1, _data(1));
        vm.expectRevert(RhTokenZap.BadMaxIn.selector);
        zap.zapFrom(address(meme), buyer, 1, 0, _data(1));
        vm.expectRevert(RhTokenZap.BadToken.selector);
        zap.zapFrom(address(usdg), buyer, 1, 1, _data(1));
        vm.stopPrank();
        address broke = address(0xD00D);
        vm.prank(broke);
        vm.expectRevert(RhTokenZap.NoBalance.selector);
        zap.zapFrom(address(meme), buyer, 1, 1, _data(1));
    }
}
