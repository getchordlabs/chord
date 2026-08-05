// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HanjiAdapter} from "../src/adapters/HanjiAdapter.sol";

/// Minimal ERC20 with allowance semantics — the Hanji proxy pulls via transferFrom.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        require(allowance[from][msg.sender] >= amt, "ALLOW");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// WMON mock with REAL deposit/withdraw — the adapter wraps native proceeds through this.
contract MockWMON is MockERC20 {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{ value: amt }("");
        require(ok, "SEND");
    }

    receive() external payable { }
}

/// Mimics the Hanji FastQuoterProxy semantics the adapter depends on:
/// - getConfig() exposes sfX/sfY/tokenX/tokenY (rest of the tuple zeroed).
/// - placeOrder (IOC sell): pulls quantity*sfX of tokenX via transferFrom, refunds the unfilled
///   remainder, pays out value - ceil(value*fee/1e18) of tokenY. No-fill returns (0,0,0,0)
///   WITHOUT reverting (full refund).
/// - placeMarketOrderWithTargetValue (buy): fee comes out of the target; pulls only
///   executedValue + fee (≤ target) of tokenY, pays out shares*sfX of tokenX.
/// - Payouts/refunds on a native-flagged side are sent as PLAIN NATIVE value-sends
///   (MockWMON.withdraw then call{value}) — exactly how the real venue behaves.
contract MockHanjiProxy {
    uint256 public sfX;
    uint256 public sfY;
    address public tokenX;
    address public tokenY;
    uint256 public priceRaw; // raw tokenY wei per 1 share of base
    uint256 public feeRate; // 1e18-scale taker fee
    uint256 public fillShares = type(uint256).max; // max = fill all; 0 = no fill; K = partial
    bool public nativeX;
    bool public nativeY;

    constructor(address tokenX_, address tokenY_, uint256 sfX_, uint256 sfY_, uint256 priceRaw_, uint256 feeRate_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
        sfX = sfX_;
        sfY = sfY_;
        priceRaw = priceRaw_;
        feeRate = feeRate_;
    }

    function setFillShares(uint256 k) external {
        fillShares = k;
    }

    function setNativeX(bool v) external {
        nativeX = v;
    }

    function getConfig()
        external
        view
        returns (
            uint256,
            uint256,
            address,
            address,
            bool,
            bool,
            address,
            address,
            uint64,
            uint64,
            uint64,
            uint64,
            bool
        )
    {
        return (
            sfX,
            sfY,
            tokenX,
            tokenY,
            nativeX || nativeY,
            false,
            address(0),
            address(0),
            0,
            uint64(feeRate),
            0,
            0,
            false
        );
    }

    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72, // price
        uint128, // maxCommission
        bool marketOnly,
        bool, // postOnly
        bool, // transferExecutedTokens
        uint256 expires
    ) external payable returns (uint64, uint128, uint128, uint128) {
        require(block.timestamp <= expires, "MOCK_EXPIRED");
        require(isAsk && marketOnly, "MOCK_UNSUPPORTED");

        // Pull the full base quantity, then refund whatever doesn't fill (real IOC behavior).
        require(MockERC20(tokenX).transferFrom(msg.sender, address(this), uint256(quantity) * sfX), "PULL");

        uint256 filled = quantity;
        if (fillShares < filled) filled = fillShares;
        uint256 refund = (uint256(quantity) - filled) * sfX;
        if (refund > 0) _payout(tokenX, nativeX, msg.sender, refund);
        if (filled == 0) return (0, 0, 0, 0); // no-fill: refunded, NOT reverted

        uint256 value = filled * priceRaw;
        uint256 fee = _ceilFee(value);
        _payout(tokenY, nativeY, msg.sender, value - fee);
        return (1, uint128(filled), uint128(value), uint128(fee));
    }

    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72, // price
        uint128, // maxCommission
        bool, // transferExecutedTokens
        uint256 expires
    ) external payable returns (uint128, uint128, uint128) {
        require(block.timestamp <= expires, "MOCK_EXPIRED");
        require(!isAsk, "MOCK_UNSUPPORTED");

        // Fee is taken FROM the target; only executedValue + fee is actually pulled.
        uint256 targetRaw = uint256(targetTokenYValue) * sfY;
        uint256 shares = (targetRaw - _ceilFee(targetRaw)) / priceRaw;
        if (fillShares < shares) shares = fillShares;
        if (shares == 0) return (0, 0, 0);

        uint256 valueRaw = shares * priceRaw;
        uint256 fee = _ceilFee(valueRaw);
        require(MockERC20(tokenY).transferFrom(msg.sender, address(this), valueRaw + fee), "PULL");
        _payout(tokenX, nativeX, msg.sender, shares * sfX);
        return (uint128(shares), uint128(valueRaw), uint128(fee));
    }

    function _ceilFee(uint256 value) internal view returns (uint256) {
        return (value * feeRate + 1e18 - 1) / 1e18;
    }

    function _payout(address token, bool asNative, address to, uint256 amt) internal {
        if (asNative) {
            MockWMON(payable(token)).withdraw(amt);
            (bool ok,) = to.call{ value: amt }("");
            require(ok, "NATIVE_SEND");
        } else {
            require(MockERC20(token).transfer(to, amt), "PAY");
        }
    }

    receive() external payable { }
}

contract HanjiAdapterTest is Test {
    MockWMON wmon;
    MockERC20 base; // 18-dec base → sfX = 1e18 (1 share = 1 whole token)
    MockERC20 quote; // 6-dec quote → sfY = 1
    MockHanjiProxy proxy; // BASE/QUOTE, pure-ERC20 market
    MockHanjiProxy nativeProxy; // WMON/QUOTE market, native payouts on the X side
    MockHanjiProxy scaledProxy; // same pair with sfY = 1000, for the buy-side dust case
    HanjiAdapter adapter;

    address recipient = address(0xDEAD);

    uint256 constant SF_X = 1e18;
    uint256 constant PRICE_RAW = 2e6; // 2 QUOTE per share
    uint256 constant FEE_RATE = 1e14; // 1bp taker fee (live MON/USDC value)

    function setUp() public {
        wmon = new MockWMON();
        base = new MockERC20();
        quote = new MockERC20();

        proxy = new MockHanjiProxy(address(base), address(quote), SF_X, 1, PRICE_RAW, FEE_RATE);
        nativeProxy = new MockHanjiProxy(address(wmon), address(quote), SF_X, 1, PRICE_RAW, FEE_RATE);
        nativeProxy.setNativeX(true);
        scaledProxy = new MockHanjiProxy(address(base), address(quote), SF_X, 1000, PRICE_RAW, FEE_RATE);

        // H1: the test contract stands in for NullRouter, and every market proxy must be on the
        // construction-time allowlist (Hanji's market list is API-served, not on-chain).
        address[] memory proxies = new address[](3);
        proxies[0] = address(proxy);
        proxies[1] = address(nativeProxy);
        proxies[2] = address(scaledProxy);
        adapter = new HanjiAdapter(address(this), address(wmon), proxies);

        // Venue inventory: quote to pay sell proceeds, base to pay buy fills.
        quote.mint(address(proxy), 1_000_000e6);
        base.mint(address(proxy), 1_000e18);
        quote.mint(address(nativeProxy), 1_000_000e6); // sell-side proceeds on the native market
        // Native market inventory: WMON backed by real native so withdraw → value-send works.
        vm.deal(address(this), 100 ether);
        wmon.deposit{ value: 100 ether }();
        wmon.transfer(address(nativeProxy), 100 ether);
    }

    // 1. Sell full fill ERC20↔ERC20: correct out, fee applied, forwarded, zero-balance, approval reset.
    function test_sell_fullFill() public {
        uint256 amountIn = 5e18; // exactly 5 shares
        base.mint(address(adapter), amountIn); // PUSH model

        uint256 amountOut =
            adapter.swap(address(base), address(quote), amountIn, recipient, abi.encode(address(proxy)));

        // value = 5 * 2e6 = 10e6; fee = ceil(10e6 * 1e14 / 1e18) = 1000
        assertEq(amountOut, 10_000_000 - 1000, "amountOut = value - fee");
        assertEq(quote.balanceOf(recipient), 9_999_000, "proceeds forwarded");
        assertEq(base.balanceOf(address(adapter)), 0, "no input stuck");
        assertEq(quote.balanceOf(address(adapter)), 0, "no output stuck");
        assertEq(base.allowance(address(adapter), address(proxy)), 0, "approval reset");
    }

    // 2. Sub-share dust input: 2.7 shares → executes 2, dust returned to `to`.
    function test_sell_subShareDust() public {
        uint256 amountIn = 2.7e18;
        base.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(base), address(quote), amountIn, recipient, abi.encode(address(proxy)));

        // 2 shares → value 4e6, fee = ceil(4e6 * 1e14 / 1e18) = 400
        assertEq(amountOut, 4_000_000 - 400, "out for 2 shares only");
        assertEq(quote.balanceOf(recipient), 3_999_600, "proceeds forwarded");
        assertEq(base.balanceOf(recipient), 0.7e18, "flooring dust returned to `to`");
        assertEq(base.balanceOf(address(adapter)), 0, "zero input balance");
        assertEq(quote.balanceOf(address(adapter)), 0, "zero output balance");
    }

    // 3. Partial fill: IOC refund of the unfilled part comes back and is returned to `to`.
    function test_sell_partialFill() public {
        proxy.setFillShares(1); // only 1 of 3 shares fills
        uint256 amountIn = 3e18;
        base.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(base), address(quote), amountIn, recipient, abi.encode(address(proxy)));

        // 1 share filled → value 2e6, fee = ceil(2e6 * 1e14 / 1e18) = 200
        assertEq(amountOut, 2_000_000 - 200, "out only for the filled share");
        assertEq(quote.balanceOf(recipient), 1_999_800, "proceeds forwarded");
        assertEq(base.balanceOf(recipient), 2e18, "IOC refund returned to `to`");
        assertEq(base.balanceOf(address(adapter)), 0, "zero input balance");
    }

    // 4. IOC no-fill: venue refunds without reverting → adapter must revert HANJI_NO_FILL.
    function test_sell_noFill_reverts() public {
        proxy.setFillShares(0);
        base.mint(address(adapter), 2e18);

        vm.expectRevert(bytes("HANJI_NO_FILL"));
        adapter.swap(address(base), address(quote), 2e18, recipient, abi.encode(address(proxy)));
    }

    // 5. Buy via targetValue: fee inside the input, output forwarded, unpulled leftover returned.
    function test_buy_targetValue() public {
        uint256 amountIn = 10_000_500; // raw quote; sfY = 1 → target = amountIn
        quote.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(quote), address(base), amountIn, recipient, abi.encode(address(proxy)));

        // feeOnTarget = ceil(10_000_500 * 1e14 / 1e18) = 1001 → spendable 9_999_499 → 4 shares
        // executed value = 8e6, fee = 800 → venue pulls 8_000_800, leftover 1_999_700 stays here
        assertEq(amountOut, 4e18, "4 whole base shares out");
        assertEq(base.balanceOf(recipient), 4e18, "output forwarded");
        assertEq(quote.balanceOf(recipient), 1_999_700, "unspent quote returned to `to`");
        assertEq(quote.balanceOf(address(adapter)), 0, "zero input balance");
        assertEq(base.balanceOf(address(adapter)), 0, "zero output balance");
        assertEq(quote.allowance(address(adapter), address(proxy)), 0, "approval reset");
    }

    // 6. Native-out buy (buy MON): proceeds arrive as a native value-send → wrap to WMON → forward.
    function test_buy_nativeOut() public {
        uint256 amountIn = 10_000_000;
        quote.mint(address(adapter), amountIn);

        uint256 amountOut =
            adapter.swap(address(quote), address(wmon), amountIn, recipient, abi.encode(address(nativeProxy)));

        // feeOnTarget = 1000 → spendable 9_999_000 → 4 shares; pulled = 8e6 + 800
        assertEq(amountOut, 4e18, "4 shares of native base, re-wrapped");
        assertEq(wmon.balanceOf(recipient), 4e18, "WMON forwarded (not raw native)");
        assertEq(quote.balanceOf(recipient), 1_999_200, "unspent quote returned to `to`");
        assertEq(address(adapter).balance, 0, "zero native balance");
        assertEq(wmon.balanceOf(address(adapter)), 0, "zero WMON balance");
        assertEq(quote.balanceOf(address(adapter)), 0, "zero input balance");
    }

    // 6b. Native-side IOC refund on the SELL path — the exact production path of swap-hanji.sh on
    //     MON/USDC (tokenX = WMON is the native side): a partial-fill sell where the proxy refunds
    //     the UNFILLED input as a plain NATIVE value-send, not WMON ERC20. The adapter must wrap
    //     that native refund back to WMON and forward it to `to` as leftover tokenIn.
    function test_sell_partialFill_nativeRefund() public {
        nativeProxy.setFillShares(1); // fills 1 of 3 shares
        uint256 amountIn = 3.5e18; // 3 shares + 0.5 fraction
        wmon.mint(address(adapter), amountIn); // PUSH model (router already wrapped MON→WMON)

        uint256 amountOut =
            adapter.swap(address(wmon), address(quote), amountIn, recipient, abi.encode(address(nativeProxy)));

        // 1 share filled → value 2e6, fee = ceil(2e6 * 1e14 / 1e18) = 200
        assertEq(amountOut, 2_000_000 - 200, "out only for the filled share");
        assertEq(quote.balanceOf(recipient), 1_999_800, "proceeds forwarded");
        // Refund of 2 unfilled shares arrived NATIVE → re-wrapped to WMON; + 0.5 flooring fraction
        // that never left the adapter → total 2.5 WMON leftover forwarded to `to`.
        assertEq(wmon.balanceOf(recipient), 2.5e18, "native refund wrapped + fraction returned as WMON");
        assertEq(address(adapter).balance, 0, "zero native balance");
        assertEq(wmon.balanceOf(address(adapter)), 0, "zero WMON balance");
        assertEq(quote.balanceOf(address(adapter)), 0, "zero output balance");
        assertEq(wmon.allowance(address(adapter), address(nativeProxy)), 0, "approval reset");
    }

    // 7a. Token not in the market's pair → HANJI_PAIR_MISMATCH.
    function test_pairMismatch_reverts() public {
        MockERC20 other = new MockERC20();
        other.mint(address(adapter), 1e18);

        vm.expectRevert(bytes("HANJI_PAIR_MISMATCH"));
        adapter.swap(address(other), address(quote), 1e18, recipient, abi.encode(address(proxy)));

        // tokenIn matches X but tokenOut is not Y → still a mismatch.
        base.mint(address(adapter), 1e18);
        vm.expectRevert(bytes("HANJI_PAIR_MISMATCH"));
        adapter.swap(address(base), address(base), 1e18, recipient, abi.encode(address(proxy)));
    }

    // 7b. Sub-1-share sell → HANJI_DUST.
    function test_sell_dust_reverts() public {
        base.mint(address(adapter), 0.5e18);
        vm.expectRevert(bytes("HANJI_DUST"));
        adapter.swap(address(base), address(quote), 0.5e18, recipient, abi.encode(address(proxy)));
    }

    // 7c. Buy where amountIn floors to a zero target (sfY > amountIn) → HANJI_DUST.
    function test_buy_dust_reverts() public {
        quote.mint(address(adapter), 999);

        vm.expectRevert(bytes("HANJI_DUST"));
        adapter.swap(address(quote), address(base), 999, recipient, abi.encode(address(scaledProxy)));
    }

    // 8. PUSH model: swap() without pre-funding must revert (venue pull fails on balance).
    function test_notPrefunded_reverts() public {
        vm.expectRevert();
        adapter.swap(address(base), address(quote), 2e18, recipient, abi.encode(address(proxy)));
    }

    // Safe-cast guard: share count above uint128 must revert, never truncate.
    function test_sell_overflow_reverts() public {
        uint256 amountIn = (uint256(type(uint128).max) + 1) * SF_X;
        vm.expectRevert(bytes("HANJI_OVERFLOW"));
        adapter.swap(address(base), address(quote), amountIn, recipient, abi.encode(address(proxy)));
    }
}
