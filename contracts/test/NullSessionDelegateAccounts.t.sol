// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NullSessionDelegate } from "../src/NullSessionDelegate.sol";
import { INullRouter } from "../src/interfaces/INullRouter.sol";

// Round 37 — a delegate that runs AT THE USER'S OWN ADDRESS.
//
// Round 31 checked the one-click executor, where authority is bounded by an ERC-20 allowance. This is
// the bigger sibling: under EIP-7702 this code executes at the EOA itself, so `address(this)` IS the
// user's wallet. Nothing sits in between — the only thing limiting the damage is what the contract
// imposes on itself. A hole here does not cost an approval, it costs the account.
//
// The existing suite is good and already avoids round 31's trap (it builds digests by hand rather
// than asking the contract). What it never does is run the delegate at more than one address, which
// is the shape 7702 actually takes in production: every user delegates the SAME bytecode, so the
// question "can a signature made for one account be used on another?" is the one that matters most.
// If the domain had been pinned to SELF (the deployed delegate) instead of address(this) (the EOA),
// every user would share a domain.
//
// vm.etch puts the runtime code at two separate EOAs — immutables travel with the bytecode, so SELF
// stays the deployed address exactly as it does under a real 7702 authorization.

contract AcctMockERC20 {
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

contract AcctMockRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        uint256,
        INullRouter.RouteStep calldata,
        address
    ) external payable returns (uint256) {
        AcctMockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 2;
        AcctMockERC20(tokenOut).transfer(msg.sender, out);
        return out;
    }
}

contract NullSessionDelegateAccountsTest is Test {
    NullSessionDelegate deployed;
    AcctMockRouter router;
    AcctMockERC20 tokenIn;
    AcctMockERC20 tokenOut;

    uint256 constant sessionPk = 0x5E5510;
    uint256 constant relayerPk = 0xBE1A1E4;
    address sessionKey;
    address relayer;

    // Two users who each delegated to the same contract.
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant CAP = 1_000e18;
    uint256 constant AMT = 100e18;
    uint256 constant MIN_OUT = 180e18;

    bytes32 constant SWAP_TYPEHASH = keccak256(
        "SessionSwap(address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        sessionKey = vm.addr(sessionPk);
        relayer = vm.addr(relayerPk);
        router = new AcctMockRouter();
        tokenIn = new AcctMockERC20();
        tokenOut = new AcctMockERC20();
        deployed = new NullSessionDelegate(address(router), relayer, address(0x1234));
        tokenOut.mint(address(router), 1_000_000e18);

        _delegate(alice);
        _delegate(bob);
    }

    /// Put the delegate's runtime code at an EOA and grant it a session, as 7702 would.
    function _delegate(address eoa) internal {
        vm.etch(eoa, address(deployed).code);
        tokenIn.mint(eoa, 10_000e18);
        address[] memory toks = new address[](2);
        toks[0] = address(tokenIn);
        toks[1] = address(tokenOut);
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP;
        caps[1] = CAP;
        vm.prank(eoa); // grantSession is a self-call
        NullSessionDelegate(payable(eoa)).grantSession(sessionKey, uint64(block.timestamp + 1 hours), toks, caps);
    }

    function _routes() internal view returns (INullRouter.RouteStep[] memory r) {
        r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({
            adapter: address(0xAD), tokenIn: address(tokenIn), tokenOut: address(tokenOut), amountIn: AMT, extraData: ""
        });
    }

    /// EIP-712 digest assembled here from the standard, with the account and chain supplied by the
    /// caller so a test can ask "what if this had been signed for someone else".
    function _digestFor(address account, uint256 chainId, uint256 amt, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                address(tokenIn),
                amt,
                address(tokenOut),
                MIN_OUT,
                keccak256(abi.encode(_routes(), NullSessionDelegate.RouteKind.Single)),
                nonce,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NullTerminal Session"), keccak256("1"), chainId, account)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _exec(address account, uint256 amt, bytes memory sessionSig, bytes memory relayerSig, uint256 nonce)
        internal
    {
        NullSessionDelegate(payable(account)).executeSession(
            address(tokenIn),
            amt,
            address(tokenOut),
            MIN_OUT,
            _routes(),
            NullSessionDelegate.RouteKind.Single,
            nonce,
            block.timestamp + 600,
            sessionSig,
            relayerSig
        );
    }

    // ── S1: the property that only exists once there are two accounts ───────────

    function test_aSignatureMadeForOneAccountIsUselessOnAnother() public {
        // Every 7702 user runs identical bytecode. If the domain named the deployed delegate instead
        // of the EOA, one signed order would drain any account that had a session open.
        uint256 dl = block.timestamp + 600;
        bytes32 forAlice = _digestFor(alice, block.chainid, AMT, 0, dl);

        vm.expectRevert(NullSessionDelegate.BadSessionSig.selector);
        _exec(bob, AMT, _sig(sessionPk, forAlice), _sig(relayerPk, forAlice), 0);

        // Same order on the account it was written for goes through.
        _exec(alice, AMT, _sig(sessionPk, forAlice), _sig(relayerPk, forAlice), 0);
        assertEq(tokenOut.balanceOf(alice), AMT * 2, "alice received the output");
        assertEq(tokenOut.balanceOf(bob), 0, "bob was never touched");
    }

    function test_theRejectedAccountKeepsItsNonce() public {
        // A refused order must not disturb the ordering of the next valid one.
        uint256 dl = block.timestamp + 600;
        bytes32 forAlice = _digestFor(alice, block.chainid, AMT, 0, dl);
        vm.expectRevert(NullSessionDelegate.BadSessionSig.selector);
        _exec(bob, AMT, _sig(sessionPk, forAlice), _sig(relayerPk, forAlice), 0);

        (,, uint64 bobNonce) = NullSessionDelegate(payable(bob)).sessionInfo();
        assertEq(bobNonce, 0, "a rejected order consumed a nonce");

        bytes32 forBob = _digestFor(bob, block.chainid, AMT, 0, dl);
        _exec(bob, AMT, _sig(sessionPk, forBob), _sig(relayerPk, forBob), 0);
        assertEq(tokenOut.balanceOf(bob), AMT * 2, "bob's own order still works");
    }

    // ── S2/S3: the rest of the domain, and the encoding itself ─────────────────

    function test_aSignatureForAnotherChainIsRejected() public {
        uint256 dl = block.timestamp + 600;
        bytes32 foreign = _digestFor(alice, block.chainid + 1, AMT, 0, dl);
        vm.expectRevert(NullSessionDelegate.BadSessionSig.selector);
        _exec(alice, AMT, _sig(sessionPk, foreign), _sig(relayerPk, foreign), 0);
    }

    function test_theIndependentlyBuiltDigestIsTheOneTheContractExpects() public {
        // If this failed, every signature test in this contract's suite would need re-reading: they
        // would all be signing the contract's own idea of the digest rather than EIP-712's.
        uint256 dl = block.timestamp + 600;
        bytes32 dg = _digestFor(alice, block.chainid, AMT, 0, dl);
        _exec(alice, AMT, _sig(sessionPk, dg), _sig(relayerPk, dg), 0);
        assertEq(tokenOut.balanceOf(alice), AMT * 2);
    }

    // ── S5/S6: the self-imposed limits, checked at the account level ────────────

    function test_theSpendCapIsCumulativeNotPerSwap() public {
        // Splitting an order into pieces must not get past the cap — otherwise the cap bounds
        // nothing at all.
        uint256 dl = block.timestamp + 600;
        uint256 chunk = CAP / 2;
        for (uint256 i = 0; i < 2; i++) {
            bytes32 dg = _digestFor(alice, block.chainid, chunk, i, dl);
            _exec(alice, chunk, _sig(sessionPk, dg), _sig(relayerPk, dg), i);
        }
        assertEq(NullSessionDelegate(payable(alice)).remainingCap(address(tokenIn)), 0, "cap spent");

        bytes32 over = _digestFor(alice, block.chainid, 1e18, 2, dl);
        vm.expectRevert(NullSessionDelegate.CapExceeded.selector);
        _exec(alice, 1e18, _sig(sessionPk, over), _sig(relayerPk, over), 2);
    }

    function test_aLeakedSessionKeyAloneCannotMoveAnything() public {
        // Two signatures is the whole safety model: the session key lives in a browser, so it has to
        // be useless without the co-signer.
        uint256 dl = block.timestamp + 600;
        bytes32 dg = _digestFor(alice, block.chainid, AMT, 0, dl);
        vm.expectRevert(NullSessionDelegate.BadRelayerSig.selector);
        _exec(alice, AMT, _sig(sessionPk, dg), _sig(sessionPk, dg), 0); // session key signs both
        assertEq(tokenOut.balanceOf(alice), 0, "nothing moved");
    }

    function test_oneAccountsGrantDoesNotGrantTheOther() public {
        // Session state lives in the EOA's own storage. Revoking on one account must leave the other
        // running — and, more importantly, granting on one must never have opened the other.
        vm.prank(alice);
        NullSessionDelegate(payable(alice)).revokeSession();

        uint256 dl = block.timestamp + 600;
        bytes32 forAlice = _digestFor(alice, block.chainid, AMT, 0, dl);
        vm.expectRevert();
        _exec(alice, AMT, _sig(sessionPk, forAlice), _sig(relayerPk, forAlice), 0);

        bytes32 forBob = _digestFor(bob, block.chainid, AMT, 0, dl);
        _exec(bob, AMT, _sig(sessionPk, forBob), _sig(relayerPk, forBob), 0);
        assertEq(tokenOut.balanceOf(bob), AMT * 2, "bob's session is independent");
    }
}
