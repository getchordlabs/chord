// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NullSessionDelegate } from "../src/NullSessionDelegate.sol";
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

contract NullSessionDelegateTest is Test {
    NullSessionDelegate d;
    MockRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 sessionPk = 0x5E5510;
    uint256 relayerPk = 0xBE1A1E4;
    uint256 attackerPk = 0xBAD;
    address sessionKey;
    address relayer;

    bytes32 constant SWAP_TYPEHASH = keccak256(
        "SessionSwap(address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 constant CAP = 1_000e18;
    uint256 constant AMT = 100e18;

    function setUp() public {
        sessionKey = vm.addr(sessionPk);
        relayer = vm.addr(relayerPk);
        router = new MockRouter();
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        d = new NullSessionDelegate(address(router), relayer, address(0x1234));

        // The delegate stands in for the 7702 EOA: it holds tokenIn, the router has tokenOut liquidity.
        tokenIn.mint(address(d), 10_000e18);
        tokenOut.mint(address(router), 1_000_000e18);

        // grant is an EOA self-call → prank the delegate as msg.sender.
        // BOTH tokenIn and tokenOut are allow-listed (tokenOut must be an allowed major to receive value).
        address[] memory toks = new address[](2);
        toks[0] = address(tokenIn);
        toks[1] = address(tokenOut);
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP;
        caps[1] = CAP;
        vm.prank(address(d));
        d.grantSession(sessionKey, uint64(block.timestamp + 1 hours), toks, caps);
    }

    function _routes() internal view returns (INullRouter.RouteStep[] memory r) {
        r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({
            adapter: address(0xAD), tokenIn: address(tokenIn), tokenOut: address(tokenOut), amountIn: AMT, extraData: ""
        });
    }

    function _digest(
        uint256 amt,
        uint256 minOut,
        uint256 nonce,
        uint256 deadline,
        INullRouter.RouteStep[] memory r,
        uint8 kind
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                address(tokenIn),
                amt,
                address(tokenOut),
                minOut,
                keccak256(abi.encode(r, kind)),
                nonce,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NullTerminal Session"), keccak256("1"), block.chainid, address(d))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _exec(uint256 amt, uint256 minOut, uint256 nonce, bytes memory sSig, bytes memory rSig) internal {
        uint256 deadline = block.timestamp + 600;
        d.executeSession(
            address(tokenIn),
            amt,
            address(tokenOut),
            minOut,
            _routes(),
            NullSessionDelegate.RouteKind.Single,
            nonce,
            deadline,
            sSig,
            rSig
        );
    }

    // ── happy path: dual-sig session swap, output to the EOA, cap decremented ──
    function test_sessionSwap() public {
        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(relayerPk, dg));

        assertEq(tokenOut.balanceOf(address(d)), 200e18, "output to EOA"); // AMT*2
        assertEq(d.remainingCap(address(tokenIn)), CAP - AMT, "cap decremented");
        (,, uint64 nonce) = d.sessionInfo();
        assertEq(nonce, 1, "nonce bumped");
    }

    // ── SINGLE sig is not enough: missing/forged relayer OR session sig reverts ──
    function test_needsBothSigs() public {
        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        // attacker has the session key but NOT the relayer key → relayer sig forged by attacker.
        vm.expectRevert(NullSessionDelegate.BadRelayerSig.selector);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(attackerPk, dg));
        // attacker has the relayer key but not the session key.
        vm.expectRevert(NullSessionDelegate.BadSessionSig.selector);
        _exec(AMT, 180e18, 0, _sig(attackerPk, dg), _sig(relayerPk, dg));
    }

    // ── cap is the hard cash bound (also the allow-list) ──
    function test_capEnforced() public {
        uint256 deadline = block.timestamp + 600;
        // spend the whole cap over the first swaps, then one more must revert.
        uint256 nonce = 0;
        for (uint256 spent = 0; spent < CAP; spent += AMT) {
            bytes32 dg = _digest(AMT, 180e18, nonce, deadline, _routes(), 0);
            _exec(AMT, 180e18, nonce, _sig(sessionPk, dg), _sig(relayerPk, dg));
            nonce++;
        }
        bytes32 dgOver = _digest(AMT, 180e18, nonce, deadline, _routes(), 0);
        vm.expectRevert(NullSessionDelegate.CapExceeded.selector);
        _exec(AMT, 180e18, nonce, _sig(sessionPk, dgOver), _sig(relayerPk, dgOver));
    }

    // ── replay: a used nonce can't be reused ──
    function test_replayReverts() public {
        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(relayerPk, dg));
        vm.expectRevert(NullSessionDelegate.BadNonce.selector);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(relayerPk, dg)); // same nonce 0
    }

    // ── expiry: past the session window everything reverts ──
    function test_expiryReverts() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        vm.expectRevert(NullSessionDelegate.SessionExpired.selector);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(relayerPk, dg));
    }

    // ── revoke kills the session immediately ──
    function test_revokeReverts() public {
        vm.prank(address(d));
        d.revokeSession();

        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        // Revoke clears the grant flag, zeroes expiry AND the session key; the M4 grant check fires
        // first — either way the session is dead and the swap reverts.
        vm.expectRevert(NullSessionDelegate.SessionNotGranted.selector);
        _exec(AMT, 180e18, 0, _sig(sessionPk, dg), _sig(relayerPk, dg));
    }

    // ── a non-allow-listed token (cap 0) can't be spent ──
    function test_notAllowlistedReverts() public {
        MockERC20 other = new MockERC20();
        other.mint(address(d), 1_000e18);
        uint256 deadline = block.timestamp + 600;
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({
            adapter: address(0xAD), tokenIn: address(other), tokenOut: address(tokenOut), amountIn: AMT, extraData: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                address(other),
                AMT,
                address(tokenOut),
                uint256(180e18),
                keccak256(abi.encode(r, uint8(0))),
                uint256(0),
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NullTerminal Session"), keccak256("1"), block.chainid, address(d))
        );
        bytes32 dg = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        vm.expectRevert(NullSessionDelegate.CapExceeded.selector); // remainingCap[other] == 0
        d.executeSession(
            address(other),
            AMT,
            address(tokenOut),
            180e18,
            r,
            NullSessionDelegate.RouteKind.Single,
            0,
            deadline,
            _sig(sessionPk, dg),
            _sig(relayerPk, dg)
        );
    }

    // ── grant/revoke are EOA-only ──
    function test_grantRevokeOnlySelf() public {
        address[] memory toks = new address[](1);
        toks[0] = address(tokenIn);
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP;
        vm.expectRevert(NullSessionDelegate.OnlySelf.selector);
        d.grantSession(sessionKey, uint64(block.timestamp + 1 hours), toks, caps); // msg.sender = test, not self
        vm.expectRevert(NullSessionDelegate.OnlySelf.selector);
        d.revokeSession();
    }

    // ── F-1: tokenOut must be allow-listed too — capped input can't be routed into an unlisted honeypot ──
    function test_tokenOutNotAllowlistedReverts() public {
        MockERC20 honeypot = new MockERC20();
        honeypot.mint(address(router), 1_000_000e18); // router "has liquidity" for it
        uint256 deadline = block.timestamp + 600;
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({
            adapter: address(0xAD), tokenIn: address(tokenIn), tokenOut: address(honeypot), amountIn: AMT, extraData: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_TYPEHASH,
                address(tokenIn),
                AMT,
                address(honeypot),
                uint256(0), // attacker self-signs minOut = 0
                keccak256(abi.encode(r, uint8(0))),
                uint256(0),
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NullTerminal Session"), keccak256("1"), block.chainid, address(d))
        );
        bytes32 dg = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        vm.expectRevert(NullSessionDelegate.TokenNotAllowed.selector);
        d.executeSession(
            address(tokenIn),
            AMT,
            address(honeypot),
            0,
            r,
            NullSessionDelegate.RouteKind.Single,
            0,
            deadline,
            _sig(sessionPk, dg),
            _sig(relayerPk, dg)
        );
    }

    // ── M6: a delegated EOA has code → ERC-1271 + receiver hooks or Permit2/NFTs break ──
    function test_isValidSignatureReturnsTheMagicValue() public {
        uint256 pk = 0xA11CE;
        address eoa = vm.addr(pk);
        vm.etch(eoa, address(d).code); // the account runs the delegate's code, as under 7702

        bytes32 hash = keccak256("permit2 witness digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        assertEq(
            NullSessionDelegate(payable(eoa)).isValidSignature(hash, abi.encodePacked(r, s, v)),
            bytes4(0x1626ba7e),
            "the account IS the signer - Permit2 must accept it"
        );
        (v, r, s) = vm.sign(uint256(0xBAD5), hash);
        assertEq(
            NullSessionDelegate(payable(eoa)).isValidSignature(hash, abi.encodePacked(r, s, v)),
            bytes4(0xffffffff),
            "a foreign signature must not validate"
        );
    }

    function test_receiverHooksAndPermissiveFallback() public {
        assertEq(d.onERC721Received(address(0), address(0), 1, ""), bytes4(0x150b7a02));
        assertEq(d.onERC1155Received(address(0), address(0), 1, 1, ""), bytes4(0xf23a6e61));
        assertTrue(d.supportsInterface(0x150b7a02));
        (bool ok,) = address(d).call(abi.encodeWithSignature("nobodyImplementsThis()"));
        assertTrue(ok, "an EOA never reverts on unknown calldata; nor may a delegated one");
    }

    // ── M4: clearing the 7702 delegation is NOT a revocation, and re-delegating must not resurrect ──
    // `revokeSession` needs a self-call, which only works while the delegate is installed. Clearing
    // the account's code leaves granted/sessionKey/expiry/caps in the EOA's storage, so re-delegating
    // to the same contract brought the whole grant back. `revokeForever()` is a PLAIN transaction to
    // the deployed delegate — it works with no code on the account and records the kill in the
    // DEPLOYED contract's storage, which no re-delegation can reach.
    function test_clearingDelegationThenReDelegatingDoesNotResurrectTheSession() public {
        NullSessionDelegate impl = new NullSessionDelegate(address(router), relayer, address(0x1234));
        address eoa = address(0xE0A);
        vm.etch(eoa, address(impl).code); // delegate installed

        tokenIn.mint(eoa, 10_000e18);
        address[] memory toks = new address[](2);
        toks[0] = address(tokenIn);
        toks[1] = address(tokenOut);
        uint256[] memory caps = new uint256[](2);
        caps[0] = CAP;
        caps[1] = CAP;
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(eoa);
        NullSessionDelegate(payable(eoa)).grantSession(sessionKey, expiry, toks, caps);

        // The user's natural "get me out of this" action: clear the delegation. Storage survives.
        vm.etch(eoa, "");
        // …so they must ALSO kill it at the deployed delegate — a plain tx, no code on the account.
        vm.prank(eoa);
        impl.revokeForever();
        assertTrue(impl.isRevokedForever(eoa), "the kill lives in the deployed contract's storage");

        // Re-delegate to the very same contract: EOA storage still says granted, key, caps, expiry.
        vm.etch(eoa, address(impl).code);
        assertEq(NullSessionDelegate(payable(eoa)).remainingCap(address(tokenIn)), CAP, "old cap is still there");

        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digestFor(eoa, AMT, 180e18, 0, deadline);
        vm.expectRevert(NullSessionDelegate.SessionKilled.selector);
        NullSessionDelegate(payable(eoa)).executeSession(
            address(tokenIn),
            AMT,
            address(tokenOut),
            180e18,
            _routes(),
            NullSessionDelegate.RouteKind.Single,
            0,
            deadline,
            _sig(sessionPk, dg),
            _sig(relayerPk, dg)
        );
    }

    // The grant flag itself: storage that this delegate never wrote can never execute.
    function test_executionRequiresAGrantThisDelegateMade() public {
        NullSessionDelegate impl = new NullSessionDelegate(address(router), relayer, address(0x1234));
        address eoa = address(0xE0B);
        vm.etch(eoa, address(impl).code);
        // No grantSession → `granted` is false even though everything else could be forged into place.
        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digestFor(eoa, AMT, 180e18, 0, deadline);
        vm.expectRevert(NullSessionDelegate.SessionNotGranted.selector);
        NullSessionDelegate(payable(eoa)).executeSession(
            address(tokenIn),
            AMT,
            address(tokenOut),
            180e18,
            _routes(),
            NullSessionDelegate.RouteKind.Single,
            0,
            deadline,
            _sig(sessionPk, dg),
            _sig(relayerPk, dg)
        );
    }

    function test_revokeForeverOnlyOnTheDeployedDelegate() public {
        NullSessionDelegate impl = new NullSessionDelegate(address(router), relayer, address(0x1234));
        address eoa = address(0xE0C);
        vm.etch(eoa, address(impl).code);
        // Called through a delegated account it would write the EOA's storage, which is exactly the
        // storage a re-delegation resurrects — reject it rather than record a kill that doesn't stick.
        vm.prank(eoa);
        vm.expectRevert(NullSessionDelegate.OnlyDeployedDelegate.selector);
        NullSessionDelegate(payable(eoa)).revokeForever();
    }

    /// Same digest as `_digest`, for an arbitrary account address (the EIP-712 domain binds it).
    function _digestFor(address account, uint256 amt, uint256 minOut, uint256 nonce, uint256 deadline)
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
                minOut,
                keccak256(abi.encode(_routes(), uint8(0))),
                nonce,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NullTerminal Session"), keccak256("1"), block.chainid, account)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ── F-2: a re-grant with a fresh token set invalidates the PRIOR session's caps (epoch bump) ──
    function test_regrantInvalidatesOldCaps() public {
        // Re-grant with ONLY tokenOut (a new majors set) — tokenIn's old cap must be gone.
        address[] memory toks = new address[](1);
        toks[0] = address(tokenOut);
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP;
        vm.prank(address(d));
        d.grantSession(sessionKey, uint64(block.timestamp + 1 hours), toks, caps);
        assertEq(d.remainingCap(address(tokenIn)), 0, "old tokenIn cap invalidated by epoch bump");
        assertEq(d.isAllowed(address(tokenIn)), false, "old tokenIn allow-list invalidated");
    }
}
