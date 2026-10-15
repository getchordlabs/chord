// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GaslessEntryPermit2, ISignatureTransfer } from "../src/GaslessEntryPermit2.sol";
import { INullRouter } from "../src/interfaces/INullRouter.sol";

/// Minimal ERC20 for the test — mintable, standard semantics.
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
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
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// Mock NullRouter: pulls tokenIn from the caller (the entry) and pays tokenOut at a fixed 2:1 rate.
/// The real router is audited separately; this isolates the NEW Permit2-witness + settle logic.
contract MockRouter {
    uint256 public constant RATE = 2; // out = in * 2

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256, /*minOut*/
        uint256, /*deadline*/
        INullRouter.RouteStep calldata,
        address /*referrer*/
    ) external payable returns (uint256) {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * RATE;
        MockERC20(tokenOut).transfer(msg.sender, out);
        return out;
    }
}

contract GaslessEntryPermit2Test is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    // Byte-matches GaslessEntryPermit2.WITNESS_TYPE_STRING — and, by construction, the relayer's and
    // the FE's copies of it (three-sided seam; see the note on WITNESS_TYPEHASH in the contract).
    bytes32 constant PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,SwapWitness witness)SwapWitness(address tokenOut,uint256 minAmountOut,uint256 relayerFee,uint256 nonce)TokenPermissions(address token,uint256 amount)"
    );

    GaslessEntryPermit2 entry;
    MockRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 userPk = 0xA11CE;
    address user;
    address relayer = address(0xBEEF);
    address wmon = address(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A); // WMON (unused by single-hop path)

    uint256 constant AMOUNT_IN = 1_000e18;

    /// @dev True only when a fork RPC is configured. Without it this suite SKIPS (see setUp) instead
    ///      of hard-failing: the 2026-08-05 audit flagged that `vm.envString` reverting in setUp made
    ///      the whole file fail in the local pre-push gate, which is why `packages/contracts/CLAUDE.md`
    ///      could claim "offline 100%" while the most security-critical gasless file never ran.
    bool internal forked;

    modifier onlyForked() {
        if (!forked) return;
        _;
    }

    function setUp() public {
        // Fork Monad so the REAL canonical Permit2 is present — the whole point is validating our
        // witness encoding against the actual Permit2 implementation, not a mock.
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no fork configured → every test no-ops via onlyForked
        vm.createSelectFork(rpc);
        forked = true;
        require(PERMIT2.code.length > 0, "Permit2 not on fork");

        user = vm.addr(userPk);
        router = new MockRouter();
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        entry = new GaslessEntryPermit2(PERMIT2, address(router), wmon, address(this));
        entry.setRelayer(relayer, true);

        tokenIn.mint(user, 10_000e18);
        tokenOut.mint(address(router), 1_000_000e18); // router liquidity
        vm.prank(user);
        tokenIn.approve(PERMIT2, type(uint256).max); // one-time Permit2 approval
    }

    // ---- Permit2 witness digest (mirrors GaslessEntryPermit2 + Permit2) ----
    function _digest(
        address _tokenIn,
        uint256 _amountIn,
        uint256 nonce,
        uint256 deadline,
        GaslessEntryPermit2.SwapWitness memory w
    ) internal view returns (bytes32) {
        bytes32 tp = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, _tokenIn, _amountIn));
        bytes32 wh = keccak256(abi.encode(entry.WITNESS_TYPEHASH(), w.tokenOut, w.minAmountOut, w.relayerFee, w.nonce));
        bytes32 structHash = keccak256(abi.encode(PERMIT_WITNESS_TYPEHASH, tp, address(entry), nonce, deadline, wh));
        bytes32 domain = _permit2Domain();
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _permit2Domain() internal view returns (bytes32 d) {
        (bool ok, bytes memory ret) = PERMIT2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "domain");
        d = abi.decode(ret, (bytes32));
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _routes() internal view returns (INullRouter.RouteStep[] memory routes) {
        routes = new INullRouter.RouteStep[](1);
        routes[0] = INullRouter.RouteStep({
            adapter: address(0xAD),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN,
            extraData: ""
        });
    }

    function _permit(uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory p)
    {
        p = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({ token: address(tokenIn), amount: AMOUNT_IN }),
            nonce: nonce,
            deadline: deadline
        });
    }

    // ---- the core: ONE signature → gasless swap, user gets output − fee ----
    function test_oneSignatureGaslessSwap() public onlyForked {
        uint256 relayerFee = 100e18;
        // out = AMOUNT_IN * 2 = 2000e18; user floor after fee:
        GaslessEntryPermit2.SwapWitness memory w = GaslessEntryPermit2.SwapWitness({
            tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: relayerFee, nonce: 0
        });
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, nonce, deadline, w));

        uint256 userInBefore = tokenIn.balanceOf(user);

        vm.prank(relayer);
        entry.execute(
            _permit(nonce, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0)
        );

        // 2000 out − 100 fee = 1900 to user; 100 to relayer.
        assertEq(tokenOut.balanceOf(user), 1_900e18, "user output");
        assertEq(tokenOut.balanceOf(relayer), relayerFee, "relayer fee");
        assertEq(tokenIn.balanceOf(user), userInBefore - AMOUNT_IN, "user input pulled");
        assertEq(tokenOut.balanceOf(address(entry)), 0, "entry holds no output");
        assertEq(tokenIn.balanceOf(address(entry)), 0, "entry holds no input");
    }

    // ---- replay: the same Permit2 nonce cannot be reused ----
    function test_replayReverts() public onlyForked {
        GaslessEntryPermit2.SwapWitness memory w =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 0, nonce: 0 });
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 0, deadline, w));

        vm.prank(relayer);
        entry.execute(_permit(0, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));

        // Same signature/nonce again → Permit2 rejects the used nonce.
        vm.prank(relayer);
        vm.expectRevert();
        entry.execute(_permit(0, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
    }

    // ---- only a whitelisted relayer can submit ----
    function test_onlyRelayer() public onlyForked {
        GaslessEntryPermit2.SwapWitness memory w =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 0, nonce: 0 });
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 0, deadline, w));

        vm.prank(address(0xD00D));
        vm.expectRevert(GaslessEntryPermit2.NotRelayer.selector);
        entry.execute(_permit(0, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
    }

    // ---- minAmountOut floor is enforced on the user's net receive ----
    function test_minOutEnforced() public onlyForked {
        // out = 2000, fee 0, but user demands 2100 → floor unmet → revert.
        GaslessEntryPermit2.SwapWitness memory w =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 2_100e18, relayerFee: 0, nonce: 0 });
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 0, deadline, w));

        vm.prank(relayer);
        vm.expectRevert();
        entry.execute(_permit(0, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
    }

    // ---- a tampered witness (relayer inflates its fee) breaks the signature ----
    function test_tamperedWitnessReverts() public onlyForked {
        GaslessEntryPermit2.SwapWitness memory signed =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 100e18, nonce: 0 });
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 0, deadline, signed));

        // Relayer tries to submit with a bigger fee than the user signed.
        GaslessEntryPermit2.SwapWitness memory tampered =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 500e18, nonce: 0 });
        vm.prank(relayer);
        vm.expectRevert(); // Permit2 recomputes the witness hash → signature mismatch
        entry.execute(
            _permit(0, deadline), user, tampered, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0)
        );
    }

    // ---- M3: at most ONE live authorisation per user ----
    // Permit2's bitmap is UNORDERED and the FE mints a random nonce per signature, so a user who
    // re-signed after a 502 or a quote refresh had 2-3 signatures live at once, each with its own
    // Permit2 slot and its own honest minOut — a compromised relayer executed ALL of them and the user
    // sold 2-3x what they intended. They hold zero native gas by definition, so they could not call
    // invalidateUnorderedNonces to cancel. This is the regression that failed before the entry kept
    // its own sequential nonce.
    function test_aSupersededAuthorisationIsNoLongerExecutable() public onlyForked {
        uint256 deadline = block.timestamp + 1 hours;

        // The user signs twice for the SAME intent (retry after a failed submit). Both carry entry
        // nonce 0; only their Permit2 (unordered) nonces differ, exactly as the FE produced them.
        GaslessEntryPermit2.SwapWitness memory w =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 0, nonce: 0 });
        bytes memory sigA = _sign(_digest(address(tokenIn), AMOUNT_IN, 111, deadline, w));
        bytes memory sigB = _sign(_digest(address(tokenIn), AMOUNT_IN, 222, deadline, w));

        vm.prank(relayer);
        entry.execute(_permit(111, deadline), user, w, sigA, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
        assertEq(entry.nonces(user), 1, "the entry's own nonce advanced");

        // The second, still-unused Permit2 nonce must now be dead.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntryPermit2.BadNonce.selector, uint256(0), uint256(1)));
        entry.execute(_permit(222, deadline), user, w, sigB, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));

        assertEq(tokenIn.balanceOf(user), 10_000e18 - AMOUNT_IN, "exactly ONE swap's worth of input left");
    }

    // The nonce is inside the witness, so the relayer cannot simply supply the current one.
    function test_relayerCannotForwardTheNonceItself() public onlyForked {
        uint256 deadline = block.timestamp + 1 hours;
        GaslessEntryPermit2.SwapWitness memory signed =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 0, nonce: 0 });
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 5, deadline, signed));

        vm.prank(relayer);
        entry.execute(_permit(5, deadline), user, signed, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));

        // Re-submitting with the witness rewritten to the new nonce breaks the Permit2 signature.
        GaslessEntryPermit2.SwapWitness memory bumped =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1_800e18, relayerFee: 0, nonce: 1 });
        vm.prank(relayer);
        vm.expectRevert();
        entry.execute(_permit(6, deadline), user, bumped, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
    }

    // ---- L4: the relayer fee must stay inside a band relative to what the swap produced ----
    function test_relayerFeeAboveTheBandReverts() public onlyForked {
        uint256 deadline = block.timestamp + 1 hours;
        // out = 2000e18. A malicious FE signs the user into a 50% fee with a floor of 1 wei — exactly
        // the shape the audit describes. Signature-valid, but out of band → revert.
        uint256 fee = 1_000e18;
        GaslessEntryPermit2.SwapWitness memory w =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1, relayerFee: fee, nonce: 0 });
        bytes memory sig = _sign(_digest(address(tokenIn), AMOUNT_IN, 0, deadline, w));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntryPermit2.FeeOutOfBand.selector, fee, uint256(2_000e18)));
        entry.execute(_permit(0, deadline), user, w, sig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));

        // 20% (the ceiling, matching the sibling stock-sell relayer's band) still goes through.
        GaslessEntryPermit2.SwapWitness memory ok =
            GaslessEntryPermit2.SwapWitness({ tokenOut: address(tokenOut), minAmountOut: 1, relayerFee: 400e18, nonce: 0 });
        bytes memory okSig = _sign(_digest(address(tokenIn), AMOUNT_IN, 1, deadline, ok));
        vm.prank(relayer);
        entry.execute(_permit(1, deadline), user, ok, okSig, _routes(), GaslessEntryPermit2.RouteKind.Single, address(0));
        assertEq(tokenOut.balanceOf(relayer), 400e18, "a fee at the band boundary is allowed");
    }

    function test_maxFeeBpsCanOnlyBeTightened() public onlyForked {
        assertEq(entry.maxFeeBps(), 2_000);
        entry.setMaxFeeBps(50);
        assertEq(entry.maxFeeBps(), 50);
        vm.expectRevert(GaslessEntryPermit2.InvalidParams.selector);
        entry.setMaxFeeBps(2_001);
    }
}
