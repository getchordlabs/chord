// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapSim} from "../../src/probes/SwapSim.sol";

contract SimToken {
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

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// A third-party router as the meta-aggregator meets it: pulls the input from msg.sender, pays `to`.
contract SimRouter {
    error Nope(uint256 code);

    function swap(SimToken tokenIn, SimToken tokenOut, uint256 amountIn, uint256 amountOut, address to) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.mint(to, amountOut);
    }

    function sellForNative(SimToken tokenIn, uint256 amountIn, uint256 amountOut, address payable to) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        (bool s,) = to.call{value: amountOut}("");
        require(s, "native send failed");
    }

    function buyWithNative(SimToken tokenOut, uint256 amountOut, address to) external payable {
        tokenOut.mint(to, amountOut);
    }

    function fail() external pure {
        revert Nope(7);
    }

    receive() external payable {}
}

contract SwapSimTest is Test {
    SimToken a;
    SimToken b;
    SimRouter router;
    address taker = address(0xA11CE);

    function setUp() public {
        a = new SimToken();
        b = new SimToken();
        router = new SimRouter();
        vm.deal(address(router), 10 ether);
        // What the api does through the eth_call state override: the runtime code sits AT the taker.
        vm.etch(taker, type(SwapSim).runtimeCode);
    }

    function _run(address tokenIn, address tokenOut, address spender, uint256 value, bytes memory data)
        internal
        returns (bool ok, uint256 received, uint256 spent, uint256 gasUsed, bytes memory ret)
    {
        vm.prank(taker, taker);
        return SwapSim(payable(taker)).run(tokenIn, tokenOut, spender, address(router), value, data);
    }

    function test_tokenToToken_measuresTheTakersOwnDelta() public {
        a.mint(taker, 100e18);
        (bool ok, uint256 received, uint256 spent, uint256 gasUsed,) = _run(
            address(a), address(b), address(router), 0, abi.encodeCall(SimRouter.swap, (a, b, 40e18, 39e18, taker))
        );
        assertTrue(ok);
        assertEq(received, 39e18);
        assertEq(spent, 40e18);
        assertGt(gasUsed, 0);
    }

    function test_outputPaidToSomeoneElse_isZeroReceived() public {
        a.mint(taker, 100e18);
        (bool ok, uint256 received,,,) = _run(
            address(a),
            address(b),
            address(router),
            0,
            abi.encodeCall(SimRouter.swap, (a, b, 40e18, 39e18, address(0xBAD)))
        );
        assertTrue(ok, "the call itself succeeds");
        assertEq(received, 0, "the taker got nothing - the api refuses this transaction");
    }

    function test_revert_isReportedWithItsData() public {
        (bool ok, uint256 received,,, bytes memory ret) =
            _run(address(a), address(b), address(router), 0, abi.encodeCall(SimRouter.fail, ()));
        assertFalse(ok);
        assertEq(received, 0);
        assertEq(bytes4(ret), SimRouter.Nope.selector);
    }

    function test_missingBalance_reverts_insteadOfPassing() public {
        (bool ok,,,,) = _run(
            address(a), address(b), address(router), 0, abi.encodeCall(SimRouter.swap, (a, b, 40e18, 39e18, taker))
        );
        assertFalse(ok, "no input balance - the pull fails");
    }

    function test_nativeOut_and_nativeIn() public {
        a.mint(taker, 5e18);
        (bool ok, uint256 received, uint256 spent,,) = _run(
            address(a),
            address(0),
            address(router),
            0,
            abi.encodeCall(SimRouter.sellForNative, (a, 5e18, 1 ether, payable(taker)))
        );
        assertTrue(ok);
        assertEq(received, 1 ether);
        assertEq(spent, 5e18);

        vm.deal(taker, 3 ether);
        (ok, received, spent,,) = _run(
            address(0), address(b), address(0), 2 ether, abi.encodeCall(SimRouter.buyWithNative, (b, 77e18, taker))
        );
        assertTrue(ok);
        assertEq(received, 77e18);
        assertEq(spent, 2 ether);
    }
}
