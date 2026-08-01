// SPDX-License-Identifier: UNLICENSED
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
        address[] memory toks = new address[](1);
        toks[0] = address(tokenIn);
        uint256[] memory caps = new uint256[](1);
        caps[0] = CAP;
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
        address[] memory toks = new address[](1);
        toks[0] = address(tokenIn);
        vm.prank(address(d));
        d.revokeSession(toks);

        uint256 deadline = block.timestamp + 600;
        bytes32 dg = _digest(AMT, 180e18, 0, deadline, _routes(), 0);
        // Revoke zeroes expiry AND the session key; the expiry check fires first — either way the
        // session is dead and the swap reverts.
        vm.expectRevert(NullSessionDelegate.SessionExpired.selector);
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
        d.revokeSession(toks);
    }
}
