// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DodoV2Adapter} from "../src/adapters/DodoV2Adapter.sol";
import {ChordDodoV2Adapter} from "../src/chord/ChordDodoV2Adapter.sol";
import {BaseAdapter} from "../src/adapters/BaseAdapter.sol";

contract DodoMockERC20 {
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

/// A DODO V2 pool as the adapter meets it: input = balance − reserve (DPPTrader.getBaseInput / getQuoteInput), output paid to `to`.
contract DodoMockPool {
    address public immutable _BASE_TOKEN_;
    address public immutable _QUOTE_TOKEN_;
    uint256 public baseReserve;
    uint256 public quoteReserve;
    uint256 public priceBps = 10_000; // quote per base, in bps of 1:1 raw units

    constructor(address base, address quote) {
        _BASE_TOKEN_ = base;
        _QUOTE_TOKEN_ = quote;
    }

    function setPrice(uint256 bps) external {
        priceBps = bps;
    }

    function sync() external {
        baseReserve = DodoMockERC20(_BASE_TOKEN_).balanceOf(address(this));
        quoteReserve = DodoMockERC20(_QUOTE_TOKEN_).balanceOf(address(this));
    }

    function sellBase(address to) external returns (uint256 out) {
        uint256 input = DodoMockERC20(_BASE_TOKEN_).balanceOf(address(this)) - baseReserve;
        out = input * priceBps / 10_000;
        DodoMockERC20(_QUOTE_TOKEN_).transfer(to, out);
        baseReserve += input;
        quoteReserve -= out;
    }

    function sellQuote(address to) external returns (uint256 out) {
        uint256 input = DodoMockERC20(_QUOTE_TOKEN_).balanceOf(address(this)) - quoteReserve;
        out = priceBps == 0 ? 0 : input * 10_000 / priceBps;
        DodoMockERC20(_BASE_TOKEN_).transfer(to, out);
        quoteReserve += input;
        baseReserve -= out;
    }
}

contract DodoMockFactory {
    mapping(address => mapping(address => address[])) internal pools;

    function add(address base, address quote, address pool) external {
        pools[base][quote].push(pool);
    }

    function getDODOPool(address base, address quote) external view returns (address[] memory) {
        return pools[base][quote];
    }
}

contract DodoV2AdapterTest is Test {
    address constant ROUTER = address(0xC0DE);
    address constant USER = address(0xB0B);
    DodoMockERC20 weth;
    DodoMockERC20 usdc;
    DodoMockPool pool;
    DodoMockFactory factory;
    DodoV2Adapter adapter;

    function setUp() public {
        weth = new DodoMockERC20();
        usdc = new DodoMockERC20();
        pool = new DodoMockPool(address(weth), address(usdc));
        weth.mint(address(pool), 1_000e18);
        usdc.mint(address(pool), 1_000e18);
        pool.sync();
        factory = new DodoMockFactory();
        factory.add(address(weth), address(usdc), address(pool));
        address[] memory fs = new address[](1);
        fs[0] = address(factory);
        adapter = new ChordDodoV2Adapter(ROUTER, fs);
    }

    function test_sell_base_and_quote_end_at_zero() public {
        weth.mint(address(adapter), 2e18);
        pool.setPrice(9_990);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(weth), address(usdc), 2e18, USER, abi.encode(address(pool)));
        assertEq(out, 1.998e18);
        assertEq(usdc.balanceOf(USER), out);
        usdc.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        uint256 back = adapter.swap(address(usdc), address(weth), 1e18, USER, abi.encode(address(pool)));
        assertGt(back, 0);
        assertEq(weth.balanceOf(USER), back);
        assertEq(weth.balanceOf(address(adapter)) + usdc.balanceOf(address(adapter)), 0, "adapter holds nothing");
    }

    function test_only_router() public {
        weth.mint(address(adapter), 1e18);
        vm.prank(USER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(weth), address(usdc), 1e18, USER, abi.encode(address(pool)));
    }

    function test_unlisted_pool_is_refused() public {
        DodoMockPool other = new DodoMockPool(address(weth), address(usdc));
        weth.mint(address(other), 10e18);
        usdc.mint(address(other), 10e18);
        other.sync();
        weth.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(DodoV2Adapter.NotDodoPool.selector, address(other)));
        adapter.swap(address(weth), address(usdc), 1e18, USER, abi.encode(address(other)));
    }

    function test_listed_under_the_reverse_order_is_not_enough() public {
        // A factory lists pools by (base, quote): the same pool filed as (quote, base) proves nothing about it.
        DodoMockFactory f2 = new DodoMockFactory();
        f2.add(address(usdc), address(weth), address(pool));
        address[] memory fs = new address[](1);
        fs[0] = address(f2);
        DodoV2Adapter a2 = new ChordDodoV2Adapter(ROUTER, fs);
        weth.mint(address(a2), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(DodoV2Adapter.NotDodoPool.selector, address(pool)));
        a2.swap(address(weth), address(usdc), 1e18, USER, abi.encode(address(pool)));
    }

    function test_pair_mismatch() public {
        DodoMockERC20 other = new DodoMockERC20();
        other.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(DodoV2Adapter.PairMismatch.selector);
        adapter.swap(address(other), address(usdc), 1e18, USER, abi.encode(address(pool)));
    }

    function test_no_fill() public {
        weth.mint(address(adapter), 1e18);
        pool.setPrice(0);
        vm.prank(ROUTER);
        vm.expectRevert(DodoV2Adapter.NoFill.selector);
        adapter.swap(address(weth), address(usdc), 1e18, USER, abi.encode(address(pool)));
    }

    function test_constructor_guards() public {
        address[] memory none = new address[](0);
        vm.expectRevert(DodoV2Adapter.ZeroAddress.selector);
        new ChordDodoV2Adapter(ROUTER, none);
        address[] memory four = new address[](4);
        for (uint256 i = 0; i < 4; i++) four[i] = address(uint160(i + 1));
        vm.expectRevert(DodoV2Adapter.TooManyFactories.selector);
        new ChordDodoV2Adapter(ROUTER, four);
        address[] memory z = new address[](1);
        vm.expectRevert(DodoV2Adapter.ZeroAddress.selector);
        new ChordDodoV2Adapter(ROUTER, z);
    }
}
