// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {SolidlyPairAdapter} from "../../src/adapters/SolidlyPairAdapter.sol";

contract PlainTokenS {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev 1 % transfer tax on every transfer (sent to a sink).
contract TaxTokenS {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        uint256 tax = v / 100;
        balanceOf[address(0xdead)] += tax;
        balanceOf[to] += v - tax;
        return true;
    }
}

/// @dev Solidly V1 volatile pair: the fee is taken off the input inside getAmountOut and inside the K check,
///      reserves are uint256 (Solidly's getReserves shape), `stable()` is reported (false here).
contract SolidlyVolatilePair {
    address public token0;
    address public token1;
    uint256 public immutable feeBps;
    bool public stable;
    uint256 private r0;
    uint256 private r1;

    constructor(address a, address b, uint256 feeBps_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        feeBps = feeBps_;
    }

    function setStableFlag(bool s) external { stable = s; }

    function sync() external {
        r0 = PlainTokenS(token0).balanceOf(address(this));
        r1 = PlainTokenS(token1).balanceOf(address(this));
    }

    function getReserves() external view returns (uint256, uint256, uint256) { return (r0, r1, 0); }

    function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256) {
        amountIn -= (amountIn * feeBps) / 10_000;
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (r0, r1) : (r1, r0);
        return (amountIn * rOut) / (rIn + amountIn);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) PlainTokenS(token0).transfer(to, amount0Out);
        if (amount1Out > 0) PlainTokenS(token1).transfer(to, amount1Out);
        uint256 b0 = PlainTokenS(token0).balanceOf(address(this));
        uint256 b1 = PlainTokenS(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "IIA");
        uint256 adj0 = b0 - (in0 * feeBps) / 10_000;
        uint256 adj1 = b1 - (in1 * feeBps) / 10_000;
        require(adj0 * adj1 >= r0 * r1, "K");
        r0 = b0;
        r1 = b1;
    }
}

contract SolidlyFactoryMock {
    mapping(bytes32 => address) internal pairs;
    function set(address a, address b, bool st, address pair) external {
        pairs[keccak256(abi.encode(a, b, st))] = pair;
        pairs[keccak256(abi.encode(b, a, st))] = pair;
    }
    function getPair(address a, address b, bool st) external view returns (address) {
        return pairs[keccak256(abi.encode(a, b, st))];
    }
}

contract SolidlyPairAdapterTest is Test {
    address constant ROUTER = address(0xA11CE);
    PlainTokenS a;
    PlainTokenS b;
    SolidlyVolatilePair pair;
    SolidlyFactoryMock factory;
    SolidlyPairAdapter adapter;

    function setUp() public {
        a = new PlainTokenS();
        b = new PlainTokenS();
        pair = new SolidlyVolatilePair(address(a), address(b), 70);
        a.mint(address(pair), 1_000_000e18);
        b.mint(address(pair), 250_000e6);
        pair.sync();
        factory = new SolidlyFactoryMock();
        factory.set(address(a), address(b), false, address(pair));
        address[] memory f = new address[](1);
        f[0] = address(factory);
        adapter = new SolidlyPairAdapter(ROUTER, f);
    }

    function _swap(address tin, address tout, uint256 amt, address p) internal returns (uint256) {
        vm.prank(ROUTER);
        return adapter.swap(tin, tout, amt, address(this), abi.encode(p));
    }

    function test_paysExactlyWhatThePairPrices_bothDirections() public {
        a.mint(address(adapter), 1_000e18);
        uint256 expected = pair.getAmountOut(1_000e18, address(a));
        uint256 out = _swap(address(a), address(b), 1_000e18, address(pair));
        assertEq(out, expected);
        assertEq(b.balanceOf(address(this)), expected);

        b.mint(address(adapter), 100e6);
        uint256 expected2 = pair.getAmountOut(100e6, address(b));
        uint256 out2 = _swap(address(b), address(a), 100e6, address(pair));
        assertEq(out2, expected2);
    }

    function test_onlyRouter() public {
        a.mint(address(adapter), 1e18);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(a), address(b), 1e18, address(this), abi.encode(address(pair)));
    }

    function test_rejectsAPoolTheFactoryDoesNotReturn() public {
        SolidlyVolatilePair fake = new SolidlyVolatilePair(address(a), address(b), 70);
        a.mint(address(fake), 1e18);
        b.mint(address(fake), 1e6);
        fake.sync();
        a.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(SolidlyPairAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(address(a), address(b), 1e18, address(this), abi.encode(address(fake)));
    }

    function test_aPoolLyingAboutStableIsRejected() public {
        pair.setStableFlag(true); // the factory registered it as volatile
        a.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(SolidlyPairAdapter.PoolNotCanonical.selector, address(pair)));
        adapter.swap(address(a), address(b), 1e18, address(this), abi.encode(address(pair)));
    }

    function test_taxedInputIsPricedOnWhatThePairReceived() public {
        TaxTokenS t = new TaxTokenS();
        SolidlyVolatilePair tp = new SolidlyVolatilePair(address(t), address(b), 70);
        t.mint(address(tp), 1_000_000e18);
        b.mint(address(tp), 250_000e6);
        tp.sync();
        factory.set(address(t), address(b), false, address(tp));
        t.mint(address(adapter), 1_000e18);
        uint256 expected = tp.getAmountOut(990e18, address(t)); // 1 % stays with the token
        uint256 out = _swap(address(t), address(b), 1_000e18, address(tp));
        assertEq(out, expected);
    }

    function test_constructorGuards() public {
        address[] memory none = new address[](0);
        vm.expectRevert(SolidlyPairAdapter.EmptyFactoryList.selector);
        new SolidlyPairAdapter(ROUTER, none);
        address[] memory z = new address[](1);
        vm.expectRevert(SolidlyPairAdapter.ZeroFactory.selector);
        new SolidlyPairAdapter(ROUTER, z);
    }
}
