// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NullOneClickExecutor } from "../src/NullOneClickExecutor.sol";
import { INullRouter } from "../src/interfaces/INullRouter.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        uint256,
        INullRouter.RouteStep calldata,
        address
    ) external payable returns (uint256) {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 2;
        MockERC20(tokenOut).transfer(msg.sender, out);
        return out;
    }
}

contract NullOneClickExecutorTest is Test {
    NullOneClickExecutor exec;
    MockRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 keeperPk = 0xBEE9;
    address keeper;
    address user = address(0xADD5E5);
    address attacker = address(0xBAD);

    uint256 constant CAP = 1_000e18;
    uint256 constant AMT = 100e18;

    function setUp() public {
        keeper = vm.addr(keeperPk);
        router = new MockRouter();
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        exec = new NullOneClickExecutor(address(router), keeper);

        // user holds tokenIn + approves the executor for the CAP; router holds tokenOut liquidity.
        tokenIn.mint(user, 10_000e18);
        tokenOut.mint(address(router), 1_000_000e18);
        vm.prank(user);
        tokenIn.approve(address(exec), CAP);
        vm.prank(user);
        exec.enableSession(uint64(block.timestamp + 1 hours));
    }

    function _routes() internal view returns (INullRouter.RouteStep[] memory r) {
        r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({
            adapter: address(0xAD), tokenIn: address(tokenIn), tokenOut: address(tokenOut), amountIn: AMT, extraData: ""
        });
    }

    function _exec(address who, uint256 amt, uint256 minOut) internal returns (uint256) {
        vm.prank(who);
        return exec.execute(
            user, address(tokenIn), amt, address(tokenOut), minOut, _routes(), NullOneClickExecutor.RouteKind.Single, block.timestamp + 600
        );
    }

    // ── happy path: keeper executes, output to the USER, allowance (= cap) decrements ──
    function test_oneClickSwap() public {
        uint256 inBefore = tokenIn.balanceOf(user);
        uint256 out = _exec(keeper, AMT, 180e18);
        assertEq(out, 200e18, "returned out"); // AMT*2
        assertEq(tokenOut.balanceOf(user), 200e18, "output to user");
        assertEq(tokenIn.balanceOf(user), inBefore - AMT, "input pulled from user");
        assertEq(tokenIn.allowance(user, address(exec)), CAP - AMT, "cap (allowance) decremented");
        assertEq(tokenIn.balanceOf(address(exec)), 0, "executor holds no input");
        assertEq(tokenOut.balanceOf(address(exec)), 0, "executor holds no output");
    }

    // ── only the keeper can execute ──
    function test_onlyKeeper() public {
        vm.expectRevert(NullOneClickExecutor.NotKeeper.selector);
        _exec(attacker, AMT, 180e18);
    }

    // ── the ERC-20 allowance is the hard spending cap ──
    function test_capBound() public {
        // spend the whole cap, then one more must revert at transferFrom (allowance exhausted).
        for (uint256 spent = 0; spent < CAP; spent += AMT) {
            _exec(keeper, AMT, 180e18);
        }
        vm.expectRevert(bytes("allowance"));
        _exec(keeper, AMT, 180e18);
    }

    // ── expired / no session reverts ──
    function test_expiredReverts() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(NullOneClickExecutor.SessionExpired.selector);
        _exec(keeper, AMT, 180e18);
    }

    // ── revoke kills the session immediately ──
    function test_revokeReverts() public {
        vm.prank(user);
        exec.revokeSession();
        vm.expectRevert(NullOneClickExecutor.SessionExpired.selector);
        _exec(keeper, AMT, 180e18);
    }

    // ── minOut floor: a swap that would fill below minOut reverts (output-to-user protection) ──
    function test_minOutReverts() public {
        // MockRouter returns AMT*2 = 200e18; ask for 300e18 → insufficient.
        vm.expectRevert(NullOneClickExecutor.InsufficientOutput.selector);
        _exec(keeper, AMT, 300e18);
    }

    // ── enable requires a future expiry; execute rejects junk params ──
    function test_badParams() public {
        vm.prank(user);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.enableSession(uint64(block.timestamp)); // not in the future

        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.execute(user, address(tokenIn), 0, address(tokenOut), 0, _routes(), NullOneClickExecutor.RouteKind.Single, block.timestamp + 600); // amountIn 0

        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.execute(user, address(tokenIn), AMT, address(tokenIn), 0, _routes(), NullOneClickExecutor.RouteKind.Single, block.timestamp + 600); // tokenIn == tokenOut
    }

    // ── re-enable with a later expiry extends; a second swap still works within the SAME allowance ──
    function test_reEnableAndSecondSwap() public {
        _exec(keeper, AMT, 180e18);
        vm.prank(user);
        exec.enableSession(uint64(block.timestamp + 2 hours));
        _exec(keeper, AMT, 180e18);
        assertEq(tokenOut.balanceOf(user), 400e18, "two swaps, both to user");
        assertEq(tokenIn.allowance(user, address(exec)), CAP - 2 * AMT, "allowance decremented twice");
    }
}
