// SPDX-License-Identifier: MIT
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
    uint256 userPk = 0xADD5E5;
    address keeper;
    address user;
    address attacker = address(0xBAD);
    address guardian; // the deployer = this test contract

    uint256 constant CAP = 1_000e18;
    uint256 constant AMT = 100e18;

    function setUp() public {
        keeper = vm.addr(keeperPk);
        user = vm.addr(userPk);
        guardian = address(this);
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

    /// The user's EIP-712 consent over the exact economics + the exact route plan.
    function _sign(uint256 pk, uint256 amt, uint256 minOut, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 rh = exec.routesHash(_routes(), NullOneClickExecutor.RouteKind.Single);
        bytes32 digest =
            exec.orderDigest(user, address(tokenIn), amt, address(tokenOut), minOut, rh, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _exec(address who, uint256 amt, uint256 minOut, bytes memory sig) internal returns (uint256) {
        // NB: read the nonce BEFORE the prank — an external call in the argument list would consume it.
        uint256 n = exec.nonces(user);
        INullRouter.RouteStep[] memory r = _routes();
        uint256 dl = block.timestamp + 600;
        vm.prank(who);
        return exec.execute(
            user, address(tokenIn), amt, address(tokenOut), minOut, r, NullOneClickExecutor.RouteKind.Single, n, dl, sig
        );
    }

    function _signedExec(address who, uint256 amt, uint256 minOut) internal returns (uint256) {
        bytes memory sig = _sign(userPk, amt, minOut, exec.nonces(user), block.timestamp + 600);
        return _exec(who, amt, minOut, sig);
    }

    // ── happy path: keeper relays a SIGNED order, output to the USER, allowance (= cap) decrements ──
    function test_oneClickSwap() public {
        uint256 inBefore = tokenIn.balanceOf(user);
        uint256 out = _signedExec(keeper, AMT, 180e18);
        assertEq(out, 200e18, "returned out"); // AMT*2
        assertEq(tokenOut.balanceOf(user), 200e18, "output to user");
        assertEq(tokenIn.balanceOf(user), inBefore - AMT, "input pulled from user");
        assertEq(tokenIn.allowance(user, address(exec)), CAP - AMT, "cap (allowance) decremented");
        assertEq(tokenIn.balanceOf(address(exec)), 0, "executor holds no input");
        assertEq(tokenOut.balanceOf(address(exec)), 0, "executor holds no output");
        assertEq(exec.nonces(user), 1, "order nonce bumped");
    }

    // ── C1: the keeper alone can move NOTHING — a swap needs the user's signature ──
    // Before the fix this call succeeded: the keeper supplied both `routes` and `minOut`, and `minOut`
    // was never validated, so `minOut = 0` + an adapter that forwards the input to a caller-chosen
    // address (H1) drained the whole allowance from one hot key with no user interaction.
    function test_keeperCannotExecuteWithoutTheUsersSignature() public {
        // (a) an empty / garbage signature is not consent.
        bytes memory junk = new bytes(65);
        vm.prank(keeper);
        vm.expectRevert();
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 1, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, junk
        );

        // (b) the keeper signing on the user's behalf is not consent either.
        bytes memory keeperSig = _sign(keeperPk, AMT, 1, 0, block.timestamp + 600);
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadSignature.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 1, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, keeperSig
        );

        assertEq(tokenIn.balanceOf(user), 10_000e18, "not a single wei of the allowance may move");
        assertEq(exec.nonces(user), 0, "no nonce consumed by a failed relay");
    }

    // ── C1: minOut = 0 is the drain shape and is rejected outright, signature or not ──
    function test_zeroMinOutIsRejected() public {
        bytes memory sig = _sign(userPk, AMT, 0, 0, block.timestamp + 600);
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 0, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── C1: the signature pins the ROUTE, so the keeper cannot swap in its own pool plan ──
    function test_keeperCannotSubstituteADifferentRoute() public {
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        INullRouter.RouteStep[] memory hostile = _routes();
        hostile[0].adapter = address(0xDEAD); // same economics, attacker's pool plan
        hostile[0].extraData = abi.encode(attacker);

        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadSignature.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, hostile,
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── C1: a user signature is single-use (replay bound) ──
    function test_signatureCannotBeReplayed() public {
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        _exec(keeper, AMT, 180e18, sig);
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadNonce.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── only the keeper can relay (a valid user signature is still not enough on its own) ──
    function test_onlyKeeper() public {
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(attacker);
        vm.expectRevert(NullOneClickExecutor.NotKeeper.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, r,
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── M7: the guardian can stop everything instantly, and can never move funds ──
    function test_guardianPauseHaltsExecutionButMovesNothing() public {
        exec.setPaused(true);
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.IsPaused.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
        // the user can still get out while paused
        vm.prank(user);
        exec.revokeSession();

        // and the guardian has no fund-moving surface at all
        assertEq(tokenIn.balanceOf(address(exec)), 0);

        exec.setPaused(false);
        vm.prank(user);
        exec.enableSession(uint64(block.timestamp + 1 hours));
        assertEq(_signedExec(keeper, AMT, 180e18), 200e18, "unpause restores execution");
    }

    function test_onlyGuardianCanPauseOrRotate() public {
        vm.prank(attacker);
        vm.expectRevert(NullOneClickExecutor.NotGuardian.selector);
        exec.setPaused(true);

        vm.prank(keeper); // not even the keeper
        vm.expectRevert(NullOneClickExecutor.NotGuardian.selector);
        exec.setKeeper(attacker);
    }

    // ── M7: keeper rotation — the old key goes dead, the new one still needs user signatures ──
    function test_keeperRotation() public {
        address newKeeper = address(0xC0FFEE);
        exec.setKeeper(newKeeper);
        assertEq(exec.keeper(), newKeeper);

        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        vm.prank(keeper); // the compromised key
        vm.expectRevert(NullOneClickExecutor.NotKeeper.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );

        assertEq(_exec(newKeeper, AMT, 180e18, sig), 200e18, "the rotated keeper relays normally");
    }

    // ── the ERC-20 allowance is the hard spending cap ──
    function test_capBound() public {
        // spend the whole cap, then one more must revert at transferFrom (allowance exhausted).
        for (uint256 spent = 0; spent < CAP; spent += AMT) {
            _signedExec(keeper, AMT, 180e18);
        }
        uint256 n = exec.nonces(user);
        bytes memory sig = _sign(userPk, AMT, 180e18, n, block.timestamp + 600);
        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(keeper);
        vm.expectRevert(bytes("allowance"));
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, r,
            NullOneClickExecutor.RouteKind.Single, n, block.timestamp + 600, sig
        );
    }

    // ── expired / no session reverts ──
    function test_expiredReverts() public {
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 2 hours + 600);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.SessionExpired.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── revoke kills the session immediately ──
    function test_revokeReverts() public {
        vm.prank(user);
        exec.revokeSession();
        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);
        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.SessionExpired.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 180e18, r,
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── minOut floor: a swap that would fill below minOut reverts (output-to-user protection) ──
    function test_minOutReverts() public {
        // MockRouter returns AMT*2 = 200e18; ask for 300e18 → insufficient.
        bytes memory sig = _sign(userPk, AMT, 300e18, 0, block.timestamp + 600);
        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.InsufficientOutput.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenOut), 300e18, r,
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        );
    }

    // ── L8: the documented 7-day session ceiling is now enforced, not just "in the future" ──
    function test_sessionWindowIsCapped() public {
        vm.prank(user);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.enableSession(type(uint64).max);

        vm.prank(user);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.enableSession(uint64(block.timestamp + 7 days + 1));

        vm.prank(user);
        exec.enableSession(uint64(block.timestamp + 7 days)); // exactly at the cap is fine
    }

    // ── enable requires a future expiry; execute rejects junk params ──
    function test_badParams() public {
        vm.prank(user);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.enableSession(uint64(block.timestamp)); // not in the future

        bytes memory sig = _sign(userPk, AMT, 180e18, 0, block.timestamp + 600);

        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.execute(
            user, address(tokenIn), 0, address(tokenOut), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        ); // amountIn 0

        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.BadParams.selector);
        exec.execute(
            user, address(tokenIn), AMT, address(tokenIn), 180e18, _routes(),
            NullOneClickExecutor.RouteKind.Single, 0, block.timestamp + 600, sig
        ); // tokenIn == tokenOut
    }

    // ── re-enable with a later expiry extends; a second swap still works within the SAME allowance ──
    function test_reEnableAndSecondSwap() public {
        _signedExec(keeper, AMT, 180e18);
        vm.prank(user);
        exec.enableSession(uint64(block.timestamp + 2 hours));
        _signedExec(keeper, AMT, 180e18);
        assertEq(tokenOut.balanceOf(user), 400e18, "two swaps, both to user");
        assertEq(tokenIn.allowance(user, address(exec)), CAP - 2 * AMT, "allowance decremented twice");
    }
}
