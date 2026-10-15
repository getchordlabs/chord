// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {PonsCurveAdapter} from "../../src/adapters/PonsCurveAdapter.sol";

/// @title PonsCurveAdapter — Pons V2 bonding curve (Robinhood Chain 4663), pre-graduation
/// @notice The test contract stands in for NullRouter throughout (it is the pinned `NULL_ROUTER`),
///         mirroring production: the router PUSHes tokenIn to the adapter, then calls swap().
///         Mock shapes are the ones measured on RH 2026-09-07: `buy(quoteIn,minOut,recipient)` payable
///         with msg.value == quoteIn for native launches, `sell(tokensIn,minOut,recipient)` paying the
///         recipient in native, and a factory `getLaunchedToken(token)` whose STATIC struct carries
///         the curve at word 1.

// ---------------------------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------------------------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(allowance[from][msg.sender] >= amt, "ALLOW");
        allowance[from][msg.sender] -= amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "BAL");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

contract MockWETH9 is MockERC20 {
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }

    function withdraw(uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "SEND");
    }
}

/// @notice Static launch record — word 1 is the curve, exactly the shape the adapter reads.
contract MockPonsFactory {
    struct Launch {
        address token;
        address curve;
        address creator;
        address feeRecipient;
        address pairToken;
        uint256 threshold;
        uint256 launchConfigId;
        uint256 tickSpacing;
    }

    mapping(address => Launch) internal launches;

    function register(address token, address curve) external {
        launches[token] = Launch(token, curve, address(0xBEEF), address(0xBEEF), address(0), 4.2 ether, 0, 200);
    }

    function getLaunchedToken(address token) external view returns (Launch memory) {
        return launches[token];
    }
}

/// @notice Linear-price curve (RATE tokens per quote unit) — enough to check plumbing, direction
///         binding and residual handling; the real curve's pricing lives in the engine's math.
contract MockPonsCurve {
    MockERC20 public immutable TOKEN;
    bool public isNativeQuote;
    address public pairToken;
    uint256 public constant RATE = 1000;
    /// @dev Quote handed back to the buyer, as a curve-finishing purchase does.
    uint256 public refund;

    constructor(MockERC20 token_, bool native_, address pair_) {
        TOKEN = token_;
        isNativeQuote = native_;
        pairToken = pair_;
    }

    function setRefund(uint256 r) external { refund = r; }

    function buy(uint256 quoteIn, uint256, address recipient) external payable returns (uint256 tokensOut) {
        if (isNativeQuote) {
            require(msg.value == quoteIn, "VALUE");
        } else {
            require(MockERC20(pairToken).transferFrom(msg.sender, address(this), quoteIn), "PULL");
        }
        tokensOut = (quoteIn - refund) * RATE;
        TOKEN.mint(recipient, tokensOut);
        if (refund > 0) {
            if (isNativeQuote) {
                (bool ok,) = msg.sender.call{value: refund}("");
                require(ok, "REFUND");
            } else {
                MockERC20(pairToken).transfer(msg.sender, refund);
            }
        }
    }

    function sell(uint256 tokensIn, uint256, address recipient) external returns (uint256 quoteOut) {
        require(TOKEN.transferFrom(msg.sender, address(this), tokensIn), "PULL");
        quoteOut = tokensIn / RATE;
        if (isNativeQuote) {
            (bool ok,) = recipient.call{value: quoteOut}("");
            require(ok, "PAY");
        } else {
            MockERC20(pairToken).transfer(recipient, quoteOut);
        }
    }

    receive() external payable {}
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

contract PonsCurveAdapterTest is Test {
    MockERC20 token;
    MockWETH9 weth;
    MockPonsFactory factory;
    MockPonsCurve curve;
    PonsCurveAdapter adapter;
    address user = address(0xA11CE);

    function setUp() public {
        token = new MockERC20();
        weth = new MockWETH9();
        factory = new MockPonsFactory();
        curve = new MockPonsCurve(token, true, address(0));
        vm.deal(address(curve), 100 ether);
        factory.register(address(token), address(curve));
        // This test contract is the pinned NullRouter.
        adapter = new PonsCurveAdapter(address(this), address(factory), address(weth));
        vm.deal(address(this), 100 ether);
    }

    /// @dev Production shape: the router pushes WETH to the adapter, then calls swap().
    function _pushWeth(uint256 amt) internal {
        weth.deposit{value: amt}();
        weth.transfer(address(adapter), amt);
    }

    function test_buy_native_unwraps_and_reports_the_measured_output() public {
        _pushWeth(1 ether);
        uint256 out = adapter.swap(address(weth), address(token), 1 ether, user, abi.encode(address(curve), true));
        assertEq(out, 1 ether * curve.RATE());
        assertEq(token.balanceOf(user), out);
        assertEq(address(adapter).balance, 0, "native stranded on the adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "WETH stranded on the adapter");
    }

    function test_buy_refund_is_forwarded_as_weth_never_stranded() public {
        curve.setRefund(0.25 ether);
        _pushWeth(1 ether);
        uint256 out = adapter.swap(address(weth), address(token), 1 ether, user, abi.encode(address(curve), true));
        assertEq(out, 0.75 ether * curve.RATE(), "reported output must be the measured token delta");
        assertEq(weth.balanceOf(user), 0.25 ether, "refund must reach `to` as WETH");
        assertEq(address(adapter).balance, 0);
    }

    function test_sell_native_wraps_the_proceeds_for_the_router() public {
        token.mint(address(adapter), 5000 ether);
        uint256 out = adapter.swap(address(token), address(weth), 5000 ether, user, abi.encode(address(curve), false));
        assertEq(out, 5000 ether / curve.RATE());
        assertEq(weth.balanceOf(user), out);
        assertEq(address(adapter).balance, 0);
        assertEq(token.allowance(address(adapter), address(curve)), 0, "approval not reset");
    }

    function test_erc20_quote_launch_buys_and_sells_with_the_pair_token() public {
        MockERC20 usdg = new MockERC20();
        MockERC20 t2 = new MockERC20();
        MockPonsCurve c2 = new MockPonsCurve(t2, false, address(usdg));
        factory.register(address(t2), address(c2));

        usdg.mint(address(adapter), 100e6);
        uint256 out = adapter.swap(address(usdg), address(t2), 100e6, user, abi.encode(address(c2), true));
        assertEq(out, 100e6 * c2.RATE());
        assertEq(t2.balanceOf(user), out);
        assertEq(usdg.allowance(address(adapter), address(c2)), 0, "quote approval not reset");

        usdg.mint(address(c2), 1e6);
        t2.mint(address(adapter), 1000e6);
        uint256 q = adapter.swap(address(t2), address(usdg), 1000e6, user, abi.encode(address(c2), false));
        assertEq(q, 1000e6 / c2.RATE());
        assertEq(usdg.balanceOf(user), q);
    }

    /// @dev H1 provenance: a curve the factory did not record for the route's token is refused,
    ///      even when it names the same token and would happily "swap".
    function test_curve_must_be_the_factorys_record_for_the_routes_token() public {
        MockPonsCurve rogue = new MockPonsCurve(token, true, address(0));
        vm.deal(address(rogue), 10 ether);
        _pushWeth(1 ether);
        vm.expectRevert(abi.encodeWithSelector(PonsCurveAdapter.CurveNotFromFactory.selector, address(rogue)));
        adapter.swap(address(weth), address(token), 1 ether, user, abi.encode(address(curve) == address(rogue) ? address(0) : address(rogue), true));
    }

    /// @dev A token with no launch record at all: curveOf() == 0 ≠ any curve.
    function test_unknown_token_has_no_curve() public {
        MockERC20 other = new MockERC20();
        assertEq(adapter.curveOf(address(other)), address(0));
        other.mint(address(adapter), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PonsCurveAdapter.CurveNotFromFactory.selector, address(curve)));
        adapter.swap(address(weth), address(other), 1 ether, user, abi.encode(address(curve), true));
    }

    /// @dev M9 binding: the right curve, but the route's quote side is not the curve's quote asset.
    function test_route_must_match_the_curves_quote_asset() public {
        MockERC20 other = new MockERC20();
        other.mint(address(adapter), 1 ether);
        vm.expectRevert(PonsCurveAdapter.TokenNotBoundToRoute.selector);
        adapter.swap(address(other), address(token), 1 ether, user, abi.encode(address(curve), true));
    }

    function test_direction_flag_must_match_the_route() public {
        token.mint(address(adapter), 1 ether);
        // isBuy=true with the token on the INPUT side: `token` = tokenOut = WETH → no launch record.
        vm.expectRevert(abi.encodeWithSelector(PonsCurveAdapter.CurveNotFromFactory.selector, address(curve)));
        adapter.swap(address(token), address(weth), 1 ether, user, abi.encode(address(curve), true));
    }

    function test_only_router_may_call_swap() public {
        vm.prank(user);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(weth), address(token), 1, user, abi.encode(address(curve), true));
    }

    function test_curveOf_reads_word_one_of_the_factory_record() public {
        assertEq(adapter.curveOf(address(token)), address(curve));
        assertEq(adapter.curveOf(address(0xDEAD)), address(0));
    }

    receive() external payable {}
}
