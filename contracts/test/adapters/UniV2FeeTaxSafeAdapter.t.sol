// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {UniV2FeeTaxSafeAdapter} from "../../src/adapters/UniV2FeeTaxSafeAdapter.sol";
import {UniV2TaxSafeAdapter} from "../../src/adapters/UniV2TaxSafeAdapter.sol";

/// @title UniV2FeeTaxSafeAdapter — the two things UniV2TaxSafeAdapter cannot do on BNB Chain
/// @notice (1) PancakeSwap V2 charges 0.25 %, not 0.3 %: the adapter must pay out exactly what a 25-bps pair
///         allows (Router02 formula with 9975). (2) BNB tax tokens "swap-and-liquify" inside `transfer` when a
///         sell lands on the pair — the token swaps its accrued tax on the SAME pair first, moving the reserves.
///         An adapter that reads reserves before the push prices against stale reserves and the pair reverts
///         `UniswapV2: K`; reading them after the push (Uniswap's own FOT router order) fills. Both are
///         reproduced offline below with a K-checking pair whose fee is a parameter.

contract PlainTokenF {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev UniswapV2Pair-shaped: reserves, token0 ordering, and the K check with a configurable fee (bps) —
///      `balance*10000 - amountIn*feeBps` exactly like PancakeSwap V2 (25) / Uniswap V2 (30).
contract FeePair {
    address public token0;
    address public token1;
    uint256 public immutable feeBps;
    uint112 private r0;
    uint112 private r1;

    constructor(address a, address b, uint256 feeBps_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        feeBps = feeBps_;
    }

    function sync() external {
        r0 = uint112(_bal(token0));
        r1 = uint112(_bal(token1));
    }

    function getReserves() external view returns (uint112, uint112, uint32) { return (r0, r1, 0); }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) PlainTokenF(token0).transfer(to, amount0Out);
        if (amount1Out > 0) PlainTokenF(token1).transfer(to, amount1Out);
        uint256 b0 = _bal(token0);
        uint256 b1 = _bal(token1);
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        uint256 adj0 = b0 * 10_000 - in0 * feeBps;
        uint256 adj1 = b1 * 10_000 - in1 * feeBps;
        require(adj0 * adj1 >= uint256(r0) * uint256(r1) * 10_000 ** 2, "UniswapV2: K");
        r0 = uint112(b0);
        r1 = uint112(b1);
    }

    function _bal(address t) internal view returns (uint256) { return PlainTokenF(t).balanceOf(address(this)); }
}

/// @dev A BNB-style tax token with swap-and-liquify: every transfer pays `taxBps` to the token contract; when
///      a transfer INTO the pair (a sell) finds the contract holding ≥ `threshold`, the token first sells its
///      whole balance into that same pair (reserves move), then credits the transfer.
contract AutoSwapTaxToken {
    mapping(address => uint256) public balanceOf;
    uint256 public immutable taxBps;
    uint256 public immutable threshold;
    address public pair;
    address public constant SINK = address(0x5111C);
    bool private inSwap;

    constructor(uint256 taxBps_, uint256 threshold_) {
        taxBps = taxBps_;
        threshold = threshold_;
    }

    function setPair(address p) external { pair = p; }
    function mint(address to, uint256 v) external { balanceOf[to] += v; }

    function transfer(address to, uint256 v) external returns (bool) {
        if (to == pair && msg.sender != address(this) && !inSwap && balanceOf[address(this)] >= threshold) {
            _autoSwap();
        }
        require(balanceOf[msg.sender] >= v, "BAL");
        uint256 tax = msg.sender == address(this) || msg.sender == pair && inSwap ? 0 : (v * taxBps) / 10_000;
        balanceOf[msg.sender] -= v;
        balanceOf[address(this)] += tax;
        balanceOf[to] += v - tax;
        return true;
    }

    function _autoSwap() internal {
        inSwap = true;
        uint256 amt = balanceOf[address(this)];
        FeePair p = FeePair(pair);
        (uint112 a, uint112 b,) = p.getReserves();
        bool isToken0 = p.token0() == address(this);
        (uint256 rIn, uint256 rOut) = isToken0 ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        balanceOf[address(this)] = 0;
        balanceOf[pair] += amt; // the token moves its own accrued tax into the pair, untaxed
        uint256 inFee = amt * (10_000 - p.feeBps());
        uint256 out = (inFee * rOut) / (rIn * 10_000 + inFee);
        p.swap(isToken0 ? 0 : out, isToken0 ? out : 0, SINK, "");
        inSwap = false;
    }
}

contract V2FactoryStub {
    mapping(bytes32 => address) public pairs;
    function set(address a, address b, address p) external {
        pairs[keccak256(abi.encode(a, b))] = p;
        pairs[keccak256(abi.encode(b, a))] = p;
    }
    function getPair(address a, address b) external view returns (address) { return pairs[keccak256(abi.encode(a, b))]; }
}

/// @dev Solidly/Velodrome registry shape: only getPair(a, b, stable).
contract SolidlyFactoryStub {
    mapping(bytes32 => address) public pairs;
    function set(address a, address b, bool stable, address p) external {
        pairs[keccak256(abi.encode(a, b, stable))] = p;
        pairs[keccak256(abi.encode(b, a, stable))] = p;
    }
    function getPair(address a, address b, bool stable) external view returns (address) {
        return pairs[keccak256(abi.encode(a, b, stable))];
    }
}

contract UniV2FeeTaxSafeAdapterTest is Test {
    address constant STRANGER = address(0xBEEF);
    address constant TO = address(0x7070);

    PlainTokenF usdt;
    PlainTokenF wbnb;
    V2FactoryStub pcsFactory; // 25 bps
    V2FactoryStub uniFactory; // 30 bps
    FeePair pcsPair;
    UniV2FeeTaxSafeAdapter adapter;

    function setUp() public {
        usdt = new PlainTokenF();
        wbnb = new PlainTokenF();
        pcsFactory = new V2FactoryStub();
        uniFactory = new V2FactoryStub();
        pcsPair = new FeePair(address(usdt), address(wbnb), 25);
        pcsFactory.set(address(usdt), address(wbnb), address(pcsPair));
        // The deepest PCS V2 pair on BNB, 2026-09-30: 39.4M USDT : 51.36k WBNB.
        usdt.mint(address(pcsPair), 39_400_603e18);
        wbnb.mint(address(pcsPair), 51_355e18);
        pcsPair.sync();
        adapter = _adapter(address(pcsFactory), 25, address(uniFactory), 30);
    }

    function _adapter(address f0, uint16 fee0, address f1, uint16 fee1) internal returns (UniV2FeeTaxSafeAdapter) {
        address[] memory fs = new address[](2);
        fs[0] = f0;
        fs[1] = f1;
        uint16[] memory fees = new uint16[](2);
        fees[0] = fee0;
        fees[1] = fee1;
        return new UniV2FeeTaxSafeAdapter(address(this), fs, fees); // this test stands in for NullRouter
    }

    function _reserves(FeePair p, address tokenIn) internal view returns (uint256 rIn, uint256 rOut) {
        (uint112 a, uint112 b,) = p.getReserves();
        (rIn, rOut) = p.token0() == tokenIn ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
    }

    // ── (1) the pool fee comes from the factory that authenticated the pair ─────────────────────

    function test_pcsV2Pair_paysTheRouter02Amount_notThe03PercentOne() public {
        uint256 amountIn = 1e18; // 1 WBNB
        wbnb.mint(address(adapter), amountIn);
        (uint256 rIn, uint256 rOut) = _reserves(pcsPair, address(wbnb));
        uint256 router02 = (amountIn * 9975 * rOut) / (rIn * 10_000 + amountIn * 9975); // PancakeRouter.getAmountOut
        uint256 at30bps = (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997); // what UniV2TaxSafeAdapter pays

        uint256 out = adapter.swap(address(wbnb), address(usdt), amountIn, TO, abi.encode(address(pcsPair)));

        assertEq(out, router02, "exactly the PancakeSwap Router02 quote");
        assertEq(usdt.balanceOf(TO), router02);
        assertGt(out, at30bps, "a hardcoded 0.3 % adapter would have under-paid");
    }

    function test_feeBelowThePairsRealFee_failsClosed() public {
        FeePair p30 = new FeePair(address(usdt), address(wbnb), 30);
        uniFactory.set(address(usdt), address(wbnb), address(p30));
        usdt.mint(address(p30), 1_000_000e18);
        wbnb.mint(address(p30), 1_300e18);
        p30.sync();
        // Mis-pinned: claims the 30-bps factory charges 25.
        UniV2FeeTaxSafeAdapter wrong = _adapter(address(uniFactory), 25, address(pcsFactory), 25);
        wbnb.mint(address(wrong), 1e18);
        vm.expectRevert(bytes("UniswapV2: K"));
        wrong.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(p30)));
    }

    function test_secondFactoryUsesItsOwnFee() public {
        FeePair p30 = new FeePair(address(usdt), address(wbnb), 30);
        uniFactory.set(address(usdt), address(wbnb), address(p30));
        usdt.mint(address(p30), 1_000_000e18);
        wbnb.mint(address(p30), 1_300e18);
        p30.sync();
        wbnb.mint(address(adapter), 1e18);
        (uint256 rIn, uint256 rOut) = _reserves(p30, address(wbnb));
        uint256 out = adapter.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(p30)));
        assertEq(out, (1e18 * 9970 * rOut) / (rIn * 10_000 + 1e18 * 9970), "30 bps for the Uniswap-style factory");
    }

    // ── (2) swap-and-liquify tax tokens: reserves must be read after the push ───────────────────

    function test_swapAndLiquifySell_fillsWhereTheTaxSafeAdapterReverts() public {
        AutoSwapTaxToken meme = new AutoSwapTaxToken(500, 1_000e18); // 5 % tax, autoswap above 1,000 accrued
        FeePair p = new FeePair(address(usdt), address(meme), 30);
        meme.setPair(address(p));
        uniFactory.set(address(usdt), address(meme), address(p));
        usdt.mint(address(p), 100_000e18);
        meme.mint(address(p), 10_000_000e18);
        p.sync();
        meme.mint(address(meme), 50_000e18); // accrued tax above the threshold: the next sell triggers the autoswap

        // Same factory, same 0.3 % fee — only the reserve-read order differs.
        address[] memory fs = new address[](1);
        fs[0] = address(uniFactory);
        UniV2TaxSafeAdapter taxSafe = new UniV2TaxSafeAdapter(address(this), fs);
        meme.mint(address(taxSafe), 100_000e18);
        vm.expectRevert(bytes("UniswapV2: K"));
        taxSafe.swap(address(meme), address(usdt), 100_000e18, TO, abi.encode(address(p)));

        meme.mint(address(adapter), 100_000e18);
        uint256 out = adapter.swap(address(meme), address(usdt), 100_000e18, TO, abi.encode(address(p)));
        assertGt(out, 0, "no output");
        assertEq(usdt.balanceOf(TO), out);
        assertEq(meme.balanceOf(address(meme)), (100_000e18 * 500) / 10_000, "autoswap ran; only this sell's tax is left");
        assertGt(usdt.balanceOf(meme.SINK()), 0, "the token's own swap happened inside the transfer");
    }

    function test_plainTaxedSell_pricesOffWhatLanded() public {
        AutoSwapTaxToken meme = new AutoSwapTaxToken(100, type(uint256).max); // 1 % tax, never autoswaps
        FeePair p = new FeePair(address(usdt), address(meme), 25);
        meme.setPair(address(p));
        pcsFactory.set(address(usdt), address(meme), address(p));
        usdt.mint(address(p), 27_000e18);
        meme.mint(address(p), 95_000_000e18);
        p.sync();
        meme.mint(address(adapter), 1_000e18);
        (uint256 rIn, uint256 rOut) = _reserves(p, address(meme));
        uint256 received = 990e18;
        uint256 out = adapter.swap(address(meme), address(usdt), 1_000e18, TO, abi.encode(address(p)));
        assertEq(out, (received * 9975 * rOut) / (rIn * 10_000 + received * 9975));
    }

    // ── provenance + guards (same as UniV2TaxSafeAdapter) ───────────────────────────────────────

    function test_rejectsACallerThatIsNotTheRouter() public {
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(pcsPair)));
    }

    function test_refusesAPairNoPinnedFactoryKnows() public {
        FeePair fake = new FeePair(address(usdt), address(wbnb), 25);
        wbnb.mint(address(adapter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(UniV2FeeTaxSafeAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(fake)));
    }

    function test_solidlyShapeRegistry_volatileOnly() public {
        SolidlyFactoryStub solid = new SolidlyFactoryStub();
        FeePair vol = new FeePair(address(usdt), address(wbnb), 20);
        FeePair stab = new FeePair(address(usdt), address(wbnb), 20);
        solid.set(address(usdt), address(wbnb), false, address(vol));
        solid.set(address(usdt), address(wbnb), true, address(stab));
        usdt.mint(address(vol), 1_000_000e18);
        wbnb.mint(address(vol), 1_300e18);
        vol.sync();
        UniV2FeeTaxSafeAdapter a = _adapter(address(solid), 20, address(pcsFactory), 25);
        wbnb.mint(address(a), 2e18);
        assertGt(a.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(vol))), 0, "volatile pair fills");
        vm.expectRevert(abi.encodeWithSelector(UniV2FeeTaxSafeAdapter.PoolNotCanonical.selector, address(stab)));
        a.swap(address(wbnb), address(usdt), 1e18, TO, abi.encode(address(stab)));
    }

    function test_aTokenThePairCannotReceiveIsRefused() public {
        AutoSwapTaxToken eater = new AutoSwapTaxToken(10_000, type(uint256).max); // 100 % tax
        FeePair p = new FeePair(address(usdt), address(eater), 25);
        eater.setPair(address(p));
        pcsFactory.set(address(usdt), address(eater), address(p));
        usdt.mint(address(p), 1_000e18);
        eater.mint(address(p), 1_000e18);
        p.sync();
        eater.mint(address(adapter), 10e18);
        vm.expectRevert(UniV2FeeTaxSafeAdapter.NothingReceived.selector);
        adapter.swap(address(eater), address(usdt), 10e18, TO, abi.encode(address(p)));
    }

    function test_constructorGuards() public {
        address[] memory none = new address[](0);
        uint16[] memory noFees = new uint16[](0);
        vm.expectRevert(UniV2FeeTaxSafeAdapter.EmptyFactoryList.selector);
        new UniV2FeeTaxSafeAdapter(address(this), none, noFees);

        address[] memory one = new address[](1);
        one[0] = address(pcsFactory);
        uint16[] memory two = new uint16[](2);
        vm.expectRevert(UniV2FeeTaxSafeAdapter.FeeListMismatch.selector);
        new UniV2FeeTaxSafeAdapter(address(this), one, two);

        uint16[] memory high = new uint16[](1);
        high[0] = 101;
        vm.expectRevert(abi.encodeWithSelector(UniV2FeeTaxSafeAdapter.FeeTooHigh.selector, uint256(101)));
        new UniV2FeeTaxSafeAdapter(address(this), one, high);

        address[] memory zero = new address[](1);
        uint16[] memory ok = new uint16[](1);
        vm.expectRevert(UniV2FeeTaxSafeAdapter.ZeroFactory.selector);
        new UniV2FeeTaxSafeAdapter(address(this), zero, ok);

        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new UniV2FeeTaxSafeAdapter(address(0), one, ok);
    }
}
