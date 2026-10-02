// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {LBPairAdapter, ILBFactoryD} from "../../src/adapters/LBPairAdapter.sol";

contract PlainTokenL {
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
contract TaxTokenL {
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

/// @dev LB-shaped pair: one fixed price (1 X = `px` Y, 18-dec fixed point), fee on the input, swaps what it received
///      above its reserves and returns amounts packed X low / Y high like LB v2.2.
contract MockLBPair {
    address public immutable tokenX;
    address public immutable tokenY;
    uint16 public immutable binStep;
    uint256 public immutable px;
    uint256 public immutable feeBps;
    uint256 public rx;
    uint256 public ry;

    constructor(address x, address y, uint16 bs, uint256 px_, uint256 feeBps_) {
        tokenX = x; tokenY = y; binStep = bs; px = px_; feeBps = feeBps_;
    }
    function getTokenX() external view returns (address) { return tokenX; }
    function getTokenY() external view returns (address) { return tokenY; }
    function getBinStep() external view returns (uint16) { return binStep; }
    function sync() external { rx = PlainTokenL(tokenX).balanceOf(address(this)); ry = PlainTokenL(tokenY).balanceOf(address(this)); }

    function quote(uint256 amountIn, bool swapForY) public view returns (uint256) {
        uint256 net = amountIn - (amountIn * feeBps) / 10_000;
        return swapForY ? (net * px) / 1e18 : (net * 1e18) / px;
    }

    function swap(bool swapForY, address to) external returns (bytes32) {
        uint256 bx = PlainTokenL(tokenX).balanceOf(address(this));
        uint256 by = PlainTokenL(tokenY).balanceOf(address(this));
        uint256 received = swapForY ? bx - rx : by - ry;
        require(received > 0, "LBPair__InsufficientAmountIn");
        uint256 out = quote(received, swapForY);
        if (swapForY) PlainTokenL(tokenY).transfer(to, out);
        else PlainTokenL(tokenX).transfer(to, out);
        rx = PlainTokenL(tokenX).balanceOf(address(this));
        ry = PlainTokenL(tokenY).balanceOf(address(this));
        return swapForY ? bytes32(out << 128) : bytes32(out);
    }
}

contract MockLBFactory {
    mapping(bytes32 => ILBFactoryD.LBPairInformation) internal info;
    function set(address x, address y, uint16 bs, address pair, bool ignored) external {
        info[keccak256(abi.encode(x, y, uint256(bs)))] = ILBFactoryD.LBPairInformation(bs, pair, true, ignored);
        info[keccak256(abi.encode(y, x, uint256(bs)))] = ILBFactoryD.LBPairInformation(bs, pair, true, ignored);
    }
    function getLBPairInformation(address x, address y, uint256 bs) external view returns (ILBFactoryD.LBPairInformation memory) {
        return info[keccak256(abi.encode(x, y, bs))];
    }
}

contract LBPairAdapterTest is Test {
    address constant ROUTER = address(0xA11CE);
    PlainTokenL x;
    PlainTokenL y;
    MockLBPair pair;
    MockLBFactory factory;
    LBPairAdapter adapter;

    function setUp() public {
        x = new PlainTokenL();
        y = new PlainTokenL();
        pair = new MockLBPair(address(x), address(y), 5, 11e6, 9); // 1 X (18d) = 11 Y (6d), 9 bps
        x.mint(address(pair), 500_000e18);
        y.mint(address(pair), 3_000_000e6);
        pair.sync();
        factory = new MockLBFactory();
        factory.set(address(x), address(y), 5, address(pair), false);
        address[] memory f = new address[](1);
        f[0] = address(factory);
        adapter = new LBPairAdapter(ROUTER, f);
    }

    function _swap(address tin, address tout, uint256 amt, address p) internal returns (uint256) {
        vm.prank(ROUTER);
        return adapter.swap(tin, tout, amt, address(this), abi.encode(p));
    }

    function test_bothDirections_decodeThePackedAmountTheyDelivered() public {
        x.mint(address(adapter), 1e18);
        uint256 q = pair.quote(1e18, true);
        assertEq(_swap(address(x), address(y), 1e18, address(pair)), q);
        assertEq(y.balanceOf(address(this)), q);

        y.mint(address(adapter), 10e6);
        uint256 q2 = pair.quote(10e6, false);
        assertEq(_swap(address(y), address(x), 10e6, address(pair)), q2);
        assertEq(x.balanceOf(address(this)), q2);
    }

    function test_onlyRouter() public {
        x.mint(address(adapter), 1e18);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(x), address(y), 1e18, address(this), abi.encode(address(pair)));
    }

    function test_rejectsAPairTheFactoryDoesNotReturn() public {
        MockLBPair fake = new MockLBPair(address(x), address(y), 5, 11e6, 9);
        x.mint(address(fake), 1e18);
        y.mint(address(fake), 100e6);
        fake.sync();
        x.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(LBPairAdapter.PairNotCanonical.selector, address(fake)));
        adapter.swap(address(x), address(y), 1e18, address(this), abi.encode(address(fake)));
    }

    function test_rejectsAPairFlaggedIgnoredForRouting() public {
        factory.set(address(x), address(y), 5, address(pair), true);
        x.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(LBPairAdapter.PairNotCanonical.selector, address(pair)));
        adapter.swap(address(x), address(y), 1e18, address(this), abi.encode(address(pair)));
    }

    function test_rejectsTokensThatAreNotThePairs() public {
        PlainTokenL z = new PlainTokenL();
        z.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(LBPairAdapter.TokenMismatch.selector);
        adapter.swap(address(z), address(y), 1e18, address(this), abi.encode(address(pair)));
    }

    function test_taxedInputIsPricedOnWhatThePairReceived() public {
        TaxTokenL t = new TaxTokenL();
        MockLBPair tp = new MockLBPair(address(t), address(y), 10, 2e6, 9);
        t.mint(address(tp), 1_000_000e18);
        y.mint(address(tp), 1_000_000e6);
        tp.sync();
        factory.set(address(t), address(y), 10, address(tp), false);
        t.mint(address(adapter), 100e18);
        uint256 expected = tp.quote(99e18, true); // 1 % stayed with the token
        assertEq(_swap(address(t), address(y), 100e18, address(tp)), expected);
    }

    function test_constructorGuards() public {
        address[] memory none = new address[](0);
        vm.expectRevert(LBPairAdapter.EmptyFactoryList.selector);
        new LBPairAdapter(ROUTER, none);
        address[] memory z = new address[](1);
        vm.expectRevert(LBPairAdapter.ZeroFactory.selector);
        new LBPairAdapter(ROUTER, z);
    }
}
