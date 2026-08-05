// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NullOneClickExecutor } from "../src/NullOneClickExecutor.sol";
import { INullRouter } from "../src/interfaces/INullRouter.sol";

// Round 31 — a signature is only as strong as what binds it.
//
// NullOneClickExecutor is the remediation for audit C1: the deployed executor lets the keeper choose
// both `routes` and `minOut` with no user signature, so a leaked keeper key drains every standing
// allowance. The fix makes a user EIP-712 signature the precondition — and it has not shipped yet,
// which is the only moment testing it is still cheap.
//
// The existing suite signs whatever `exec.orderDigest(...)` returns. That proves the contract is
// self-consistent; it cannot prove the digest is the one the spec describes, because a wrong domain
// would be signed just as wrongly by the test. Every digest here is built INDEPENDENTLY from the
// EIP-712 text, so these tests fail if the contract's encoding drifts from the standard — and they
// cover the three places a valid signature could be replayed somewhere it was never meant for.

contract SigMockERC20 {
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

contract SigMockRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        uint256,
        INullRouter.RouteStep calldata,
        address
    ) external payable returns (uint256) {
        SigMockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 2;
        SigMockERC20(tokenOut).transfer(msg.sender, out);
        return out;
    }
}

/// Reports a healthy number and transfers a fraction of it — the shape a compromised or buggy
/// adapter takes. Only a measured balance delta catches this; a trusted return value does not.
contract LyingRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        uint256,
        INullRouter.RouteStep calldata,
        address
    ) external payable returns (uint256) {
        SigMockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        SigMockERC20(tokenOut).transfer(msg.sender, amountIn / 10); // sends a tenth…
        return amountIn * 2; // …and claims double
    }
}

contract NullOneClickExecutorSigTest is Test {
    NullOneClickExecutor exec;
    SigMockRouter router;
    SigMockERC20 tokenIn;
    SigMockERC20 tokenOut;

    uint256 constant keeperPk = 0xBEE9;
    uint256 constant userPk = 0xADD5E5;
    address keeper;
    address user;

    uint256 constant CAP = 1_000e18;
    uint256 constant AMT = 100e18;
    uint256 constant MIN_OUT = 180e18;

    // The EIP-712 text, restated here from the standard rather than read back off the contract.
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant ORDER_TYPEHASH = keccak256(
        "OneClickOrder(address user,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        keeper = vm.addr(keeperPk);
        user = vm.addr(userPk);
        router = new SigMockRouter();
        tokenIn = new SigMockERC20();
        tokenOut = new SigMockERC20();
        exec = new NullOneClickExecutor(address(router), keeper);

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

    /// A digest assembled from the EIP-712 text, with the domain fields supplied by the caller so a
    /// test can ask "what if this had been signed for another chain / another deployment".
    function _independentDigest(uint256 chainId, address verifyingContract, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("NullTerminal OneClick"), keccak256("1"), chainId, verifyingContract
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                user,
                address(tokenIn),
                AMT,
                address(tokenOut),
                MIN_OUT,
                keccak256(abi.encode(_routes(), NullOneClickExecutor.RouteKind.Single)),
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _run(bytes memory sig, uint256 nonce, uint256 deadline) internal returns (uint256) {
        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(keeper);
        return exec.execute(
            user,
            address(tokenIn),
            AMT,
            address(tokenOut),
            MIN_OUT,
            r,
            NullOneClickExecutor.RouteKind.Single,
            nonce,
            deadline,
            sig
        );
    }

    // ── N1: the encoding is the standard one, not merely self-consistent ─────────

    function test_acceptsADigestBuiltIndependentlyFromTheEip712Text() public {
        // If this fails, every signature test in the suite has to be re-read: they sign whatever the
        // contract hands them, so a wrong domain or a drifted typehash would pass unnoticed.
        uint256 dl = block.timestamp + 600;
        bytes memory sig = _sign(_independentDigest(block.chainid, address(exec), 0, dl));
        uint256 out = _run(sig, 0, dl);
        assertEq(out, AMT * 2, "the contract must accept the standard encoding");
        assertEq(tokenOut.balanceOf(user), AMT * 2, "output goes to the user");
        assertEq(exec.nonces(user), 1, "nonce consumed");
    }

    function test_theContractsOwnDigestMatchesTheIndependentOne() public view {
        // Stated as an equality so a future refactor of orderDigest() cannot drift from the spec
        // while every existing test keeps passing.
        uint256 dl = block.timestamp + 600;
        bytes32 mine = _independentDigest(block.chainid, address(exec), 0, dl);
        bytes32 theirs = exec.orderDigest(
            user,
            address(tokenIn),
            AMT,
            address(tokenOut),
            MIN_OUT,
            exec.routesHash(_routes(), NullOneClickExecutor.RouteKind.Single),
            0,
            dl
        );
        assertEq(mine, theirs, "contract digest diverged from the EIP-712 text");
    }

    // ── N2/N3: the two replays that this deployment plan makes real ─────────────

    function test_aSignatureForAnotherChainIsRejected() public {
        // The executor is meant to run on Monad 143 AND Robinhood 4663 (see CHAINS in
        // routes/gasless.ts). Without chainId in the domain, one signature spends on both.
        uint256 dl = block.timestamp + 600;
        bytes memory foreign = _sign(_independentDigest(block.chainid + 1, address(exec), 0, dl));
        vm.expectRevert(NullOneClickExecutor.BadSignature.selector);
        _run(foreign, 0, dl);
        assertEq(exec.nonces(user), 0, "a rejected order consumes nothing");
    }

    function test_aSignatureForAnotherDeploymentIsRejected() public {
        // The C1 fix ships as a NEW address, so the old and new executors coexist. A signature bound
        // to one must be inert at the other, or shipping a new address achieves nothing.
        NullOneClickExecutor other = new NullOneClickExecutor(address(router), keeper);
        uint256 dl = block.timestamp + 600;
        bytes memory forOther = _sign(_independentDigest(block.chainid, address(other), 0, dl));
        vm.expectRevert(NullOneClickExecutor.BadSignature.selector);
        _run(forOther, 0, dl);
        assertEq(exec.nonces(user), 0, "a rejected order consumes nothing");
    }

    // ── N4: nonces are a sequence, not a set ────────────────────────────────────

    function test_aSignatureForAFutureNonceCannotBeUsedEarly() public {
        // Pre-signing several orders is normal UX. If the keeper could pick which one to run, it
        // would pick by price, not by the user's intent — replay protection has to mean ORDER too.
        uint256 dl = block.timestamp + 600;
        bytes memory future = _sign(_independentDigest(block.chainid, address(exec), 1, dl));
        vm.expectRevert(NullOneClickExecutor.BadNonce.selector);
        _run(future, 1, dl);

        // And it works once its turn genuinely comes.
        _run(_sign(_independentDigest(block.chainid, address(exec), 0, dl)), 0, dl);
        _run(future, 1, dl);
        assertEq(exec.nonces(user), 2, "both orders consumed, in order");
    }

    // ── N5/N6: the output number is measured, not taken on trust ────────────────

    function test_aRouterThatOverstatesItsOutputCannotClearMinOut() public {
        // The executor reads a balance delta rather than the router's return value. Anything else
        // would let a compromised adapter report a healthy fill while sending a tenth of it.
        LyingRouter lying = new LyingRouter();
        tokenOut.mint(address(lying), 1_000_000e18); // the ROUTER needs the liquidity, not the executor
        NullOneClickExecutor liar = new NullOneClickExecutor(address(lying), keeper);
        vm.prank(user);
        tokenIn.approve(address(liar), CAP);
        vm.prank(user);
        liar.enableSession(uint64(block.timestamp + 1 hours));

        uint256 dl = block.timestamp + 600;
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("NullTerminal OneClick"), keccak256("1"), block.chainid, address(liar)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                user,
                address(tokenIn),
                AMT,
                address(tokenOut),
                MIN_OUT,
                keccak256(abi.encode(_routes(), NullOneClickExecutor.RouteKind.Single)),
                0,
                dl
            )
        );
        bytes memory sig = _sign(keccak256(abi.encodePacked("\x19\x01", domain, structHash)));

        INullRouter.RouteStep[] memory r = _routes();
        vm.prank(keeper);
        vm.expectRevert(NullOneClickExecutor.InsufficientOutput.selector);
        liar.execute(
            user,
            address(tokenIn),
            AMT,
            address(tokenOut),
            MIN_OUT,
            r,
            NullOneClickExecutor.RouteKind.Single,
            0,
            dl,
            sig
        );
    }

    function test_theExecutorKeepsNothingAfterASuccessfulOrder() public {
        uint256 dl = block.timestamp + 600;
        _run(_sign(_independentDigest(block.chainid, address(exec), 0, dl)), 0, dl);
        assertEq(tokenIn.balanceOf(address(exec)), 0, "no input dust left behind");
        assertEq(tokenOut.balanceOf(address(exec)), 0, "no output dust left behind");
    }
}
