// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {UniV2TaxSafeAdapter} from "../../src/adapters/UniV2TaxSafeAdapter.sol";
import {TaxProbe, TaxScratch} from "../../src/probes/TaxProbe.sol";

/// @title UniV2TaxSafeAdapter + TaxProbe — Arc's taxed V2 tokens
/// @notice Measured on Arc 2026-09-16: every token on the official Uniswap V2 factory takes 1–2 % on
///         each transfer. The generic adapter priced off `amountIn` and reverted `UniswapV2: K` on
///         every sell (`0xcce28865…`, `0xb4495e4a…`). This suite reproduces that pair + token shape
///         offline: a real constant-product pair with the K invariant, a token that skims `taxBps` on
///         every transfer, and (for the probe) the engine's eth_call state-override trick done with
///         `vm.etch` — code placed AT the pair's address so the probe runs as the pair.

contract TaxToken {
    mapping(address => uint256) public balanceOf;
    uint256 public immutable taxBps;
    address public immutable sink = address(0xFEE);

    constructor(uint256 taxBps_) { taxBps = taxBps_; }

    function mint(address to, uint256 v) external { balanceOf[to] += v; }

    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        uint256 fee = (v * taxBps) / 10_000;
        balanceOf[sink] += fee;
        balanceOf[to] += v - fee;
        return true;
    }
}

contract PlainToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev A faithful-enough UniswapV2Pair: reserves, K check on the post-swap balances (with the 0.3 %
///      fee adjustment), token0 ordering — the parts that made the real sells revert.
contract MockPair {
    address public token0;
    address public token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function sync() external {
        r0 = uint112(_bal(token0));
        r1 = uint112(_bal(token1));
    }

    function getReserves() external view returns (uint112, uint112, uint32) { return (r0, r1, 0); }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) PlainToken(token0).transfer(to, amount0Out);
        if (amount1Out > 0) PlainToken(token1).transfer(to, amount1Out);
        uint256 b0 = _bal(token0);
        uint256 b1 = _bal(token1);
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        uint256 adj0 = b0 * 1000 - in0 * 3;
        uint256 adj1 = b1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(r0) * uint256(r1) * 1000 ** 2, "UniswapV2: K");
        r0 = uint112(b0);
        r1 = uint112(b1);
    }

    function _bal(address t) internal view returns (uint256) { return PlainToken(t).balanceOf(address(this)); }
}

contract FactoryStub {
    mapping(bytes32 => address) public pairs;
    function set(address a, address b, address p) external { pairs[keccak256(abi.encode(a, b))] = p; pairs[keccak256(abi.encode(b, a))] = p; }
    function getPair(address a, address b) external view returns (address) { return pairs[keccak256(abi.encode(a, b))]; }
}

contract UniV2TaxSafeAdapterTest is Test {
    address constant STRANGER = address(0xBEEF);
    address constant TO = address(0x7070);

    PlainToken usdc;
    TaxToken meme; // 1 % tax
    MockPair pair;
    FactoryStub factory;
    UniV2TaxSafeAdapter adapter;

    function setUp() public {
        usdc = new PlainToken();
        meme = new TaxToken(100);
        pair = new MockPair(address(usdc), address(meme));
        factory = new FactoryStub();
        factory.set(address(usdc), address(meme), address(pair));
        address[] memory fs = new address[](1);
        fs[0] = address(factory);
        adapter = new UniV2TaxSafeAdapter(address(this), fs);
        // Seed the pair: mint straight in (no tax on mint) — 27k USDC : 95.6M meme (the Big pair).
        usdc.mint(address(pair), 26_904e6);
        meme.mint(address(pair), 95_601_712e18);
        pair.sync();
    }

    // ── the failure the generic adapter had: a taxed SELL ───────────────────────────────────────

    function test_sellOfATaxedToken_executesOnWhatThePairReceived() public {
        uint256 amountIn = 1_000e18;
        meme.mint(address(adapter), amountIn); // router push (the adapter's own balance is taxed on the way OUT to the pair)
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = pair.token0() == address(meme) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 received = amountIn * 99 / 100;
        uint256 expected = (received * 997 * rOut) / (rIn * 1000 + received * 997);

        uint256 out = adapter.swap(address(meme), address(usdc), amountIn, TO, abi.encode(address(pair)));

        assertEq(out, expected, "priced off the 1 %-taxed amount that actually landed");
        assertEq(usdc.balanceOf(TO), expected);
        uint256 naive = (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997);
        assertLt(out, naive, "the naive amountIn price would have failed K");
    }

    function test_buyOfATaxedToken_isPricedLikeTheGenericAdapter() public {
        // USDC in is untaxed: received == amountIn, so the output equals the plain V2 formula; the
        // tax lands on the pair -> TO transfer, which the router's measured-output guard sees.
        uint256 amountIn = 300e6;
        usdc.mint(address(adapter), amountIn);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = pair.token0() == address(usdc) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expected = (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997);
        uint256 out = adapter.swap(address(usdc), address(meme), amountIn, TO, abi.encode(address(pair)));
        assertEq(out, expected, "untaxed input prices off amountIn");
        assertEq(meme.balanceOf(TO), expected - (expected * 100) / 10_000, "the recipient eats the transfer tax on the way out");
    }

    // ── H1 ──────────────────────────────────────────────────────────────────────────────────────

    function test_rejectsACallerThatIsNotTheRouter() public {
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(usdc), address(meme), 1e6, TO, abi.encode(address(pair)));
    }

    function test_refusesAPairTheFactoryDoesNotKnow() public {
        MockPair fake = new MockPair(address(usdc), address(meme));
        usdc.mint(address(adapter), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniV2TaxSafeAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(address(usdc), address(meme), 1e6, TO, abi.encode(address(fake)));
    }

    function test_aTokenThePairCannotReceiveIsRefused() public {
        TaxToken eater = new TaxToken(10_000); // 100 % tax
        MockPair p2 = new MockPair(address(usdc), address(eater));
        factory.set(address(usdc), address(eater), address(p2));
        usdc.mint(address(p2), 1_000e6);
        eater.mint(address(p2), 1_000e18);
        p2.sync();
        eater.mint(address(adapter), 10e18);
        vm.expectRevert(UniV2TaxSafeAdapter.NothingReceived.selector);
        adapter.swap(address(eater), address(usdc), 10e18, TO, abi.encode(address(p2)));
    }

    function test_constructorGuards() public {
        address[] memory none = new address[](0);
        vm.expectRevert(UniV2TaxSafeAdapter.EmptyFactoryList.selector);
        new UniV2TaxSafeAdapter(address(this), none);
        address[] memory zero = new address[](1);
        vm.expectRevert(UniV2TaxSafeAdapter.ZeroFactory.selector);
        new UniV2TaxSafeAdapter(address(this), zero);
    }

    // ── TaxProbe: the engine's measurement, done the way eth_call state overrides do it ───────────

    function test_taxProbe_measuresBothDirectionsFromInsideThePair() public {
        address scratch = address(0x5C4A7C);
        vm.etch(scratch, type(TaxScratch).runtimeCode);
        // Put the probe AT the pair: it now owns the pair's meme balance and calls as the pair.
        vm.etch(address(pair), type(TaxProbe).runtimeCode);
        (uint256 buyRecv, uint256 sellRecv) = TaxProbe(address(pair)).probe(address(meme), scratch);
        assertEq(buyRecv, 9_900, "buyer receives 99 % of what the pair sends");
        assertEq(sellRecv, 9_900, "pair receives 99 % of what a seller sends");
        vm.etch(address(pair), type(TaxProbe).runtimeCode);
        (uint256 b2, uint256 s2) = TaxProbe(address(pair)).probe(address(usdc), scratch);
        assertEq(b2, 10_000, "untaxed token reads 100 %");
        assertEq(s2, 10_000);
    }
}
