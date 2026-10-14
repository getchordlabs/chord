// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WooFiAdapter} from "../src/adapters/WooFiAdapter.sol";
import {ChordWooFiAdapter} from "../src/chord/ChordWooFiAdapter.sol";
import {BaseAdapter} from "../src/adapters/BaseAdapter.sol";

contract WooMockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// WooPPV2 as the adapter meets it: input arrives by transfer BEFORE `swap`, checked as `balance - reserve`
/// (WooPPV2 `_sellBase` / `_sellQuote` / `_swapBaseToBase`), output paid straight to `to`, a fixed rate per call.
contract WooMockPool {
    address public immutable quoteToken;
    mapping(address => uint256) public reserve;
    uint256 public rateBps = 10_000;
    address public lastRebateTo;
    address public lastTo;

    constructor(address quote_) {
        quoteToken = quote_;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function sync(address token) external {
        reserve[token] = WooMockERC20(token).balanceOf(address(this));
    }

    function swap(address fromToken, address toToken, uint256 fromAmount, uint256, address to, address rebateTo)
        external
        returns (uint256 out)
    {
        require(WooMockERC20(fromToken).balanceOf(address(this)) - reserve[fromToken] >= fromAmount, "WooPPV2: !BASE");
        reserve[fromToken] += fromAmount;
        out = fromAmount * rateBps / 10_000;
        reserve[toToken] -= out;
        lastRebateTo = rebateTo;
        lastTo = to;
        WooMockERC20(toToken).transfer(to, out);
    }
}

contract WooFiAdapterTest is Test {
    address constant ROUTER = address(0xC0DE);
    address constant USER = address(0xB0B);
    WooMockERC20 usdc;
    WooMockERC20 weth;
    WooMockPool pool;
    WooFiAdapter adapter;

    function setUp() public {
        usdc = new WooMockERC20();
        weth = new WooMockERC20();
        pool = new WooMockPool(address(usdc));
        usdc.mint(address(pool), 1_000_000e6);
        weth.mint(address(pool), 1_000e18);
        pool.sync(address(usdc));
        pool.sync(address(weth));
        adapter = new ChordWooFiAdapter(ROUTER, address(pool));
    }

    function _push(WooMockERC20 t, uint256 amt) internal {
        t.mint(address(adapter), amt); // the router pushes tokenIn to the adapter before swap()
    }

    function test_swap_pays_to_and_ends_at_zero() public {
        _push(usdc, 1_000e6);
        pool.setRate(9_990);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(usdc), address(weth), 1_000e6, USER, abi.encode(address(pool)));
        assertEq(out, 999e6, "the pool's rate on the raw amount");
        assertEq(weth.balanceOf(USER), out, "delivered to `to`");
        assertEq(usdc.balanceOf(address(adapter)), 0, "input left in the adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "output left in the adapter");
        assertEq(pool.lastTo(), address(adapter), "the pool pays the adapter, which measures and forwards");
        assertEq(pool.lastRebateTo(), ROUTER, "rebateTo names the Chord router");
    }

    function test_reverse_direction() public {
        _push(weth, 5e6); // the mock prices 1:1 in raw units; keep inside its 1,000,000e6 USDC reserve
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(weth), address(usdc), 5e6, USER, abi.encode(address(pool)));
        assertEq(usdc.balanceOf(USER), out);
        assertGt(out, 0);
    }

    function test_only_router() public {
        _push(usdc, 1e6);
        vm.prank(USER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(usdc), address(weth), 1e6, USER, abi.encode(address(pool)));
    }

    function test_rejects_any_other_pool() public {
        WooMockPool other = new WooMockPool(address(usdc));
        _push(usdc, 1e6);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(WooFiAdapter.NotWooPool.selector, address(other)));
        adapter.swap(address(usdc), address(weth), 1e6, USER, abi.encode(address(other)));
    }

    function test_rejects_same_token() public {
        _push(usdc, 1e6);
        vm.prank(ROUTER);
        vm.expectRevert(WooFiAdapter.SameToken.selector);
        adapter.swap(address(usdc), address(usdc), 1e6, USER, abi.encode(address(pool)));
    }

    function test_no_fill_reverts() public {
        _push(usdc, 1e6);
        pool.setRate(0);
        vm.prank(ROUTER);
        vm.expectRevert(WooFiAdapter.NoFill.selector);
        adapter.swap(address(usdc), address(weth), 1e6, USER, abi.encode(address(pool)));
    }

    function test_input_short_of_the_amount_reverts_in_the_pool() public {
        _push(usdc, 1e6 - 1); // the router pushed less than it claims: the pool's balance-minus-reserve check refuses
        vm.prank(ROUTER);
        vm.expectRevert();
        adapter.swap(address(usdc), address(weth), 1e6, USER, abi.encode(address(pool)));
    }

    function test_constructor_guards() public {
        vm.expectRevert(WooFiAdapter.ZeroAddress.selector);
        new ChordWooFiAdapter(ROUTER, address(0));
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new ChordWooFiAdapter(address(0), address(pool));
    }
}
