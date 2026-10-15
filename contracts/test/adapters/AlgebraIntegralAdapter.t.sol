// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {AlgebraIntegralAdapter} from "../../src/adapters/AlgebraIntegralAdapter.sol";

contract TokAI {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

interface ICallbackAI {
    function algebraSwapCallback(int256, int256, bytes calldata) external;
}

/// @dev Integral-shaped pool at a fixed 1:2 price; `fillBps` < 10_000 simulates a partial fill (consumes less input).
contract MockIntegralPool {
    address public token0;
    address public token1;
    uint256 public fillBps = 10_000;
    constructor(address a, address b) { token0 = a; token1 = b; }
    function setFill(uint256 f) external { fillBps = f; }
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 inUsed = uint256(amountRequired) * fillBps / 10_000;
        uint256 out = zeroToOne ? inUsed * 2 : inUsed / 2;
        (amount0, amount1) = zeroToOne ? (int256(inUsed), -int256(out)) : (-int256(out), int256(inUsed));
        address tin = zeroToOne ? token0 : token1;
        uint256 before = TokAI(tin).balanceOf(address(this));
        ICallbackAI(msg.sender).algebraSwapCallback(amount0, amount1, data);
        require(TokAI(tin).balanceOf(address(this)) - before >= inUsed, "IIA");
        TokAI(zeroToOne ? token1 : token0).transfer(recipient, out);
    }
}

contract MockIntegralFactory {
    mapping(bytes32 => address) internal def;
    mapping(bytes32 => address) internal custom;
    function setDefault(address a, address b, address p) external { def[keccak256(abi.encode(a, b))] = p; def[keccak256(abi.encode(b, a))] = p; }
    function setCustom(address d, address a, address b, address p) external {
        custom[keccak256(abi.encode(d, a, b))] = p; custom[keccak256(abi.encode(d, b, a))] = p;
    }
    function poolByPair(address a, address b) external view returns (address) { return def[keccak256(abi.encode(a, b))]; }
    function customPoolByPair(address d, address a, address b) external view returns (address) { return custom[keccak256(abi.encode(d, a, b))]; }
}

contract AlgebraIntegralAdapterTest is Test {
    address constant ROUTER = address(0xA11CE);
    address constant DEPLOYER = address(0xD3);
    TokAI a;
    TokAI b;
    MockIntegralPool pool;
    MockIntegralFactory factory;
    AlgebraIntegralAdapter adapter;

    function setUp() public {
        a = new TokAI();
        b = new TokAI();
        pool = new MockIntegralPool(address(a), address(b));
        a.mint(address(pool), 1e30);
        b.mint(address(pool), 1e30);
        factory = new MockIntegralFactory();
        factory.setCustom(DEPLOYER, address(a), address(b), address(pool));
        address[] memory fs = new address[](1);
        address[] memory ds = new address[](1);
        fs[0] = address(factory);
        ds[0] = DEPLOYER;
        adapter = new AlgebraIntegralAdapter(ROUTER, fs, ds);
    }

    function _swap(address tin, address tout, uint256 amt) internal returns (uint256) {
        vm.prank(ROUTER);
        return adapter.swap(tin, tout, amt, address(this), abi.encode(address(pool)));
    }

    function test_customDeployerPool_bothWays() public {
        a.mint(address(adapter), 100e18);
        assertEq(_swap(address(a), address(b), 100e18), 200e18);
        assertEq(b.balanceOf(address(this)), 200e18);
        b.mint(address(adapter), 10e18);
        assertEq(_swap(address(b), address(a), 10e18), 5e18);
    }

    function test_defaultEntryRefusesACustomPool_andAcceptsADefaultOne() public {
        address[] memory fs = new address[](1);
        address[] memory ds = new address[](1);
        fs[0] = address(factory);
        AlgebraIntegralAdapter d = new AlgebraIntegralAdapter(ROUTER, fs, ds);
        a.mint(address(d), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(AlgebraIntegralAdapter.PoolNotRegistered.selector, address(pool)));
        d.swap(address(a), address(b), 1e18, address(this), abi.encode(address(pool)));
        factory.setDefault(address(a), address(b), address(pool));
        vm.prank(ROUTER);
        assertEq(d.swap(address(a), address(b), 1e18, address(this), abi.encode(address(pool))), 2e18);
    }

    function test_onlyRouter_andCallbackGate() public {
        a.mint(address(adapter), 1e18);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(a), address(b), 1e18, address(this), abi.encode(address(pool)));
        vm.expectRevert(bytes("unauthorized callback"));
        adapter.algebraSwapCallback(1e18, -1, abi.encode(address(a)));
    }

    function test_pairMismatch() public {
        TokAI z = new TokAI();
        z.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(AlgebraIntegralAdapter.PairMismatch.selector);
        adapter.swap(address(z), address(b), 1e18, address(this), abi.encode(address(pool)));
    }

    function test_partialFill_sweepsUnspentInputToRecipient() public {
        pool.setFill(6_000);
        a.mint(address(adapter), 100e18);
        assertEq(_swap(address(a), address(b), 100e18), 120e18);
        assertEq(a.balanceOf(address(this)), 40e18);
        assertEq(a.balanceOf(address(adapter)), 0);
    }

    function test_constructorGuards() public {
        address[] memory none = new address[](0);
        vm.expectRevert(AlgebraIntegralAdapter.EmptyVenueList.selector);
        new AlgebraIntegralAdapter(ROUTER, none, none);
        address[] memory one = new address[](1);
        address[] memory two = new address[](2);
        vm.expectRevert(AlgebraIntegralAdapter.LengthMismatch.selector);
        new AlgebraIntegralAdapter(ROUTER, one, two);
        vm.expectRevert(AlgebraIntegralAdapter.ZeroFactory.selector);
        new AlgebraIntegralAdapter(ROUTER, one, one);
    }
}
