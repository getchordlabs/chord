// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {NullOrderBook} from "../src/NullOrderBook.sol";

/// Minimal ERC20 with a public mint (test-only). Treats max allowance as infinite.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _x(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "ALLOWANCE"); allowance[f][msg.sender] = al - a; }
        _x(f, to, a); return true;
    }
    function _x(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

/// Fee-on-transfer ERC20 (standalone — no inheritance so no override dance):
/// receiver gets 1% less than sent, so escrow accounting must reject it.
contract MockFOT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _x(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "ALLOWANCE"); allowance[f][msg.sender] = al - a; }
        _x(f, to, a); return true;
    }
    function _x(address f, address to, uint256 a) internal {
        require(balanceOf[f] >= a, "BAL");
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100; // burn 1%
    }
}

/// WMON mock: ERC20 + deposit (mint on native in) + withdraw (burn + send native out).
contract MockWMON is MockERC20 {
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "WMON_BAL");
        balanceOf[msg.sender] -= a;
        (bool ok, ) = msg.sender.call{value: a}("");
        require(ok, "WMON_SEND");
    }
    receive() external payable {}
}

contract MockRegistry { function isApproved(address) external pure returns (bool) { return true; } }

/// Records the referrer the router forwards so tests can assert referral plumbing.
contract MockFeeCollector {
    address public lastReferrer = address(0xDEAD);
    uint256 public lastFee;
    function feeBps() external pure returns (uint16) { return 5; }
    function feeBpsFor(address) external pure returns (uint16) { return 5; }
    function collectFee(address, uint256 amount, address referrer) external { lastReferrer = referrer; lastFee = amount; }
}

/// Mints `amountIn` of tokenOut (1:1) to `to`; ignores the tokenIn it was sent.
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// The H3 primitive (audit 2026-08-05): a "pool" the keeper controls. It ignores the input entirely
/// and credits EXACTLY the amount the keeper decided — the keeper sells the maker's real input at
/// market elsewhere in the same tx and hands back precisely the floor. Indistinguishable from an
/// honest fill at the event level, which is why the floor alone cannot be the only protection.
contract MockSkimAdapter {
    uint256 public out;

    function setOut(uint256 o) external { out = o; }

    function swap(address, address tokenOut, uint256, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, out);
        return out;
    }
}

/// Reference-price source. Both test tokens are 18-dec, so "market" is `amountIn * rateBps / 1e4`.
contract MockOracle {
    uint256 public rateBps = 10_000;
    bool public broken;
    uint256 public answer0;

    function setRateBps(uint256 r) external { rateBps = r; }
    function setBroken(bool b) external { broken = b; }
    function setAnswerZero(bool z) external { answer0 = z ? 1 : 0; }

    function referenceOut(address, address, uint256 amountIn) external view returns (uint256) {
        require(!broken, "ORACLE_DOWN");
        if (answer0 == 1) return 0;
        return (amountIn * rateBps) / 10_000;
    }
}

contract NullOrderBookTest is Test {
    NullRouter router;
    NullOrderBook book;
    MockERC20 tA;
    MockERC20 tB;
    MockWMON wmon;
    MockFeeCollector fc;
    MockSkimAdapter skim;
    MockOracle oracle;
    address _adp;

    address maker = address(0xBEEF);
    address keeper = address(0xCAFE);
    address referrer = address(0xFEE5);

    /// Timestamp anchor for the schedule tests. MUST be storage, not a local: under via_ir the
    /// optimiser treats TIMESTAMP as invariant within a call and rematerialises it, so a local
    /// snapshot silently tracks `vm.warp` instead of holding the value it was assigned.
    uint64 t0;

    uint128 constant FILL = 100 ether;
    // MockAdapter mints 1:1 and the router takes a 5bps fee from output.
    uint256 constant FILL_OUT = uint256(FILL) - (uint256(FILL) * 5) / 10_000;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        wmon = new MockWMON();
        fc = new MockFeeCollector();
        MockRegistry reg = new MockRegistry();
        _adp = address(new MockAdapter());
        skim = new MockSkimAdapter();
        oracle = new MockOracle();

        NullRouter impl = new NullRouter();
        bytes memory initData = abi.encodeCall(
            NullRouter.initialize,
            (address(this), address(wmon), address(0), address(fc), address(reg))
        );
        router = NullRouter(payable(address(new ERC1967Proxy(address(impl), initData))));

        book = new NullOrderBook(address(router), address(wmon), address(this));
        book.setKeeper(keeper, true);

        vm.deal(address(wmon), 1_000_000 ether); // native backing for withdraw()
        tA.mint(maker, 1_000_000 ether);
        vm.deal(maker, 1_000_000 ether);
        vm.prank(maker);
        tA.approve(address(book), type(uint256).max);
    }

    // ---- helpers ----

    function _route(address tin, address tout, uint256 amt) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({adapter: _adp, tokenIn: tin, tokenOut: tout, amountIn: amt, extraData: ""});
    }

    function _routes1(address tin, address tout, uint256 amt) internal view returns (INullRouter.RouteStep[] memory r) {
        r = new INullRouter.RouteStep[](1);
        r[0] = _route(tin, tout, amt);
    }

    /// Same shape, but through a keeper-chosen adapter (the H3 "self-owned pool").
    function _routes1Via(address adapter, address tin, address tout, uint256 amt)
        internal
        pure
        returns (INullRouter.RouteStep[] memory r)
    {
        r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({adapter: adapter, tokenIn: tin, tokenOut: tout, amountIn: amt, extraData: ""});
    }

    /// Gross output the adapter must credit so the maker nets exactly `net` after the router's 5bps.
    function _grossFor(uint256 net) internal pure returns (uint256) {
        uint256 g = (net * 10_000) / 9_995;
        while (g - (g * 5) / 10_000 < net) g++;
        return g;
    }

    function _createLimit(address tin, address tout, uint128 minOut) internal returns (uint256) {
        uint256 value = tin == address(0) ? FILL : 0;
        vm.prank(maker);
        return book.createOrder{value: value}(
            tin, tout, FILL, minOut, 1, 0, uint64(block.timestamp + 1 days), address(0)
        );
    }

    // ============================================================
    // createOrder
    // ============================================================

    function test_create_escrowserc20_andIndexes() public {
        uint256 balBefore = tA.balanceOf(maker);
        vm.prank(maker);
        uint256 id = book.createOrder(
            address(tA), address(tB), FILL, 1, 3, 1 hours, uint64(block.timestamp + 1 days), referrer
        );
        assertEq(tA.balanceOf(maker), balBefore - uint256(FILL) * 3, "escrow pulled");
        assertEq(tA.balanceOf(address(book)), uint256(FILL) * 3, "book holds escrow");
        assertEq(book.openOrderCount(), 1);
        assertEq(book.openOrderIds()[0], id);
        assertEq(book.ordersOf(maker).length, 1);
        NullOrderBook.Order memory o = book.getOrder(id);
        assertEq(o.maker, maker);
        assertEq(o.numFills, 3);
        assertEq(o.referrer, referrer);
    }

    function test_create_native_requiresExactValue() public {
        vm.prank(maker);
        vm.expectRevert(NullOrderBook.BadEscrowAmount.selector);
        book.createOrder{value: 1 ether}(
            address(0), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 1 days), address(0)
        );
        // exact value works
        vm.prank(maker);
        book.createOrder{value: FILL}(
            address(0), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 1 days), address(0)
        );
        assertEq(address(book).balance, FILL);
    }

    function test_create_paramValidation() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.startPrank(maker);
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tB), 0, 1, 1, 0, exp, address(0)); // zero amount
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tB), FILL, 0, 1, 0, exp, address(0)); // zero floor
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tB), FILL, 1, 0, 0, exp, address(0)); // zero fills
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tB), FILL, 1, 2, 0, exp, address(0)); // DCA w/o interval
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tA), FILL, 1, 1, 0, exp, address(0)); // same token
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.createOrder(address(tA), address(tB), FILL, 1, 1, 0, uint64(block.timestamp), address(0)); // expired
        vm.expectRevert(NullOrderBook.UnexpectedNative.selector);
        book.createOrder{value: 1}(address(tA), address(tB), FILL, 1, 1, 0, exp, address(0)); // native on ERC20
        vm.stopPrank();
    }

    function test_create_rejectsFeeOnTransfer() public {
        MockFOT fot = new MockFOT();
        fot.mint(maker, 1_000 ether);
        vm.startPrank(maker);
        fot.approve(address(book), type(uint256).max);
        vm.expectRevert(NullOrderBook.BadEscrowAmount.selector);
        book.createOrder(address(fot), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 1 days), address(0));
        vm.stopPrank();
    }

    function test_create_dropsSelfReferral() public {
        vm.prank(maker);
        uint256 id = book.createOrder(
            address(tA), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 1 days), maker
        );
        assertEq(book.getOrder(id).referrer, address(0), "self-referral must be dropped");
    }

    // ============================================================
    // executeFill — limit orders
    // ============================================================

    function test_fill_limit_happyPath() public {
        uint256 id = _createLimit(address(tA), address(tB), uint128(FILL_OUT));
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        assertEq(tB.balanceOf(maker), FILL_OUT, "maker received output");
        assertEq(tA.balanceOf(address(book)), 0, "escrow fully spent");
        assertEq(book.openOrderCount(), 0, "order closed");
        NullOrderBook.Order memory o = book.getOrder(id);
        assertEq(o.filledCount, 1);
        // approval revoked
        assertEq(tA.allowance(address(book), address(router)), 0, "approval must be revoked");
    }

    function test_fill_onlyKeeper() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.prank(maker);
        vm.expectRevert(NullOrderBook.NotKeeper.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
    }

    function test_fill_belowFloor_reverts() public {
        // Floor ABOVE what the route delivers (FILL_OUT) → router's own minOut check reverts.
        uint256 id = _createLimit(address(tA), address(tB), uint128(FILL_OUT + 1));
        vm.prank(keeper);
        vm.expectRevert();
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        // Order stays open + escrow intact.
        assertEq(book.openOrderCount(), 1);
        assertEq(tA.balanceOf(address(book)), FILL);
    }

    function test_fill_cancelled_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.prank(maker);
        book.cancelOrder(id);
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.OrderNotOpen.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
    }

    function test_fill_expired_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.OrderExpired.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        // cancel still refunds after expiry
        uint256 balBefore = tA.balanceOf(maker);
        vm.prank(maker);
        book.cancelOrder(id);
        assertEq(tA.balanceOf(maker) - balBefore, FILL, "post-expiry refund");
    }

    function test_fill_doubleFill_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.startPrank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        vm.expectRevert(NullOrderBook.OrderNotOpen.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        vm.stopPrank();
    }

    function test_fill_forwardsReferrer() public {
        vm.prank(maker);
        uint256 id = book.createOrder(
            address(tA), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 1 days), referrer
        );
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(fc.lastReferrer(), referrer, "referrer must flow through to the fee collector");
    }

    // ============================================================
    // executeFill — native MON legs
    // ============================================================

    function test_fill_nativeIn() public {
        uint256 id = _createLimit(address(0), address(tB), uint128(FILL_OUT));
        assertEq(address(book).balance, FILL);
        vm.prank(keeper);
        // Router native-in convention: route legs say WMON, msg.value carries the MON.
        book.executeFill(id, _routes1(address(wmon), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(tB.balanceOf(maker), FILL_OUT, "maker received output");
        assertEq(address(book).balance, 0, "native escrow spent");
    }

    function test_fill_nativeOut() public {
        uint256 id = _createLimit(address(tA), address(0), uint128(FILL_OUT));
        uint256 balBefore = maker.balance;
        vm.prank(keeper);
        // Native out: route produces WMON, router unwraps → book.receive → maker.
        book.executeFill(id, _routes1(address(tA), address(wmon), FILL), NullOrderBook.RouteKind.Single);
        assertEq(maker.balance - balBefore, FILL_OUT, "maker received native MON");
        assertEq(address(book).balance, 0, "book keeps no native");
    }

    function test_receive_rejectsNonRouter() public {
        vm.deal(address(0xABCD), 1 ether);
        vm.prank(address(0xABCD));
        (bool ok, ) = address(book).call{value: 1 ether}("");
        assertFalse(ok, "stray native transfers must revert");
    }

    // ============================================================
    // executeFill — multi-hop pinning
    // ============================================================

    function test_fill_multiHop_happyPath() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = _route(address(tA), address(wmon), FILL);
        r[1] = _route(address(wmon), address(tB), 0); // 0 = chain prior output
        vm.prank(keeper);
        book.executeFill(id, r, NullOrderBook.RouteKind.MultiHop);
        assertGt(tB.balanceOf(maker), 0, "maker received multi-hop output");
    }

    function test_fill_multiHop_wrongEntryToken_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = _route(address(tB), address(wmon), FILL); // entry != order.tokenIn
        r[1] = _route(address(wmon), address(tB), 0);
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.InvalidRoutePlan.selector);
        book.executeFill(id, r, NullOrderBook.RouteKind.MultiHop);
    }

    function test_fill_multiHop_wrongExitToken_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = _route(address(tA), address(wmon), FILL);
        r[1] = _route(address(wmon), address(tA), 0); // exit != order.tokenOut
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.InvalidRoutePlan.selector);
        book.executeFill(id, r, NullOrderBook.RouteKind.MultiHop);
    }

    // ============================================================
    // DCA schedules
    // ============================================================

    function test_dca_fillsRespectInterval_andComplete() public {
        vm.prank(maker);
        uint256 id = book.createOrder(
            address(tA), address(tB), FILL, uint128(FILL_OUT), 3, 1 hours, uint64(block.timestamp + 30 days), address(0)
        );

        // fill 1 — immediate
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).filledCount, 1);

        // fill 2 — too early
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.FillTooEarly.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        NullOrderBook.Order memory o = book.getOrder(id);
        assertEq(o.filledCount, 3, "all fills executed");
        assertEq(book.openOrderCount(), 0, "completed order closed");
        assertEq(tB.balanceOf(maker), FILL_OUT * 3, "maker received all fills");
        assertEq(tA.balanceOf(address(book)), 0, "escrow exactly consumed");
    }

    function test_dca_cancelMidway_refundsRemaining() public {
        vm.prank(maker);
        uint256 id = book.createOrder(
            address(tA), address(tB), FILL, 1, 3, 1 hours, uint64(block.timestamp + 30 days), address(0)
        );
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        uint256 balBefore = tA.balanceOf(maker);
        vm.prank(maker);
        book.cancelOrder(id);
        assertEq(tA.balanceOf(maker) - balBefore, uint256(FILL) * 2, "2 unfilled fills refunded");
        assertEq(book.openOrderCount(), 0);
    }

    function test_cancel_onlyMaker() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.NotMaker.selector);
        book.cancelOrder(id);
    }

    function test_cancel_double_reverts() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.startPrank(maker);
        book.cancelOrder(id);
        vm.expectRevert(NullOrderBook.OrderNotOpen.selector);
        book.cancelOrder(id);
        vm.stopPrank();
    }

    // ============================================================
    // H3 — keeper surplus bound (audit 2026-08-05)
    // ============================================================

    /// DCA order at the shipped 5% FE default. The keeper routes through a pool it owns and
    /// credits PRECISELY the floor, keeping the other ~5%. Both of the contract's pre-existing
    /// checks pass (the router's minAmountOut and the book's own balance-delta floor check) —
    /// this reverts only because of the oracle bound.
    function test_fill_keeperAtExactFloor_revertsUnderOracleBound() public {
        book.setOracle(address(oracle), 100); // reference must be met within 1%

        uint128 floor = uint128((uint256(FILL) * 9_500) / 10_000); // FE's 5% DCA default
        uint256 id = _createLimit(address(tA), address(tB), floor);
        skim.setOut(_grossFor(floor)); // hand back exactly the floor, net of the router's fee

        // received = the floor to the wei; the reference says 100, the bound says >= 99.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(NullOrderBook.OracleBoundViolated.selector, uint256(floor), uint256(99 ether))
        );
        book.executeFill(id, _routes1Via(address(skim), address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        // Nothing moved: escrow intact, order still open, maker unharmed.
        assertEq(tA.balanceOf(address(book)), FILL, "escrow intact");
        assertEq(tB.balanceOf(maker), 0, "no output delivered");
        assertEq(book.openOrderCount(), 1, "order still open");
    }

    /// The same order filled honestly (market output) clears the bound — the check must not block
    /// legitimate fills, only the skim.
    function test_fill_honestFill_clearsOracleBound() public {
        book.setOracle(address(oracle), 100);
        uint128 floor = uint128((uint256(FILL) * 9_500) / 10_000);
        uint256 id = _createLimit(address(tA), address(tB), floor);

        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(tB.balanceOf(maker), FILL_OUT, "honest fill delivered");
    }

    /// Degrades safely: with no oracle configured the book behaves exactly as it did pre-audit —
    /// the maker's floor is the only check, and the skim goes through. This is the documented
    /// trust assumption, pinned so it cannot silently change.
    function test_fill_atFloor_allowedWhenOracleUnset() public {
        uint128 floor = uint128((uint256(FILL) * 9_500) / 10_000);
        uint256 id = _createLimit(address(tA), address(tB), floor);
        skim.setOut(_grossFor(floor));

        vm.prank(keeper);
        book.executeFill(id, _routes1Via(address(skim), address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertGe(tB.balanceOf(maker), floor, "floor honoured");
        assertLt(tB.balanceOf(maker), FILL_OUT, "only the floor - exactly what the oracle bound closes");
    }

    /// A configured-but-broken oracle fails CLOSED. Falling back to the floor on error would be
    /// the exact bypass the bound exists to remove.
    function test_fill_oracleReverting_failsClosed() public {
        book.setOracle(address(oracle), 100);
        oracle.setBroken(true);
        uint256 id = _createLimit(address(tA), address(tB), 1);

        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.OracleUnavailable.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
    }

    function test_fill_oracleZeroAnswer_failsClosed() public {
        book.setOracle(address(oracle), 100);
        oracle.setAnswerZero(true);
        uint256 id = _createLimit(address(tA), address(tB), 1);

        vm.prank(keeper);
        vm.expectRevert(NullOrderBook.OracleUnavailable.selector);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
    }

    function test_setOracle_onlyOwner_andBounded() public {
        vm.prank(maker);
        vm.expectRevert();
        book.setOracle(address(oracle), 100);

        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.setOracle(address(oracle), 5_001); // > 50% deviation is not a bound
        vm.expectRevert(NullOrderBook.InvalidParams.selector);
        book.setOracle(address(oracle), 0); // configured oracle with a no-op deviation

        book.setOracle(address(oracle), 100);
        assertEq(address(book.oracle()), address(oracle));
        assertEq(book.maxDeviationBps(), 100);

        book.setOracle(address(0), 0); // disable path
        assertEq(address(book.oracle()), address(0));
    }

    // ============================================================
    // H3 — keeper timing discretion
    // ============================================================

    function _createDca(uint128 minOut) internal returns (uint256) {
        vm.prank(maker);
        return book.createOrder(
            address(tA), address(tB), FILL, minOut, 3, 1 hours, uint64(block.timestamp + 30 days), address(0)
        );
    }

    /// A due DCA slot stays fillable for `maxFillDelay` and then closes — the keeper cannot hold
    /// the slot open across the whole interval shopping for a dip that still clears the floor.
    function test_dca_fillWindow_closesThenReopensNextInterval() public {
        t0 = uint64(block.timestamp);
        uint256 id = _createDca(uint128(FILL_OUT));

        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).nextFillTime, t0 + 1 hours);

        // 20 min late on a 15-min window → slot closed.
        vm.warp(t0 + 1 hours + 20 minutes);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(NullOrderBook.FillWindowMissed.selector, uint256(20 minutes), uint64(15 minutes))
        );
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        // The window reopens at the next boundary — a missed slot self-heals, it never bricks.
        vm.warp(t0 + 2 hours);
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).filledCount, 2);
    }

    /// Limit orders are exempt by design: "fill whenever price crosses" IS the product.
    function test_limit_notSubjectToFillWindow() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.warp(block.timestamp + 12 hours); // far past any window, still inside expiry
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).filledCount, 1);
    }

    function test_setMaxFillDelay_zeroDisablesWindow() public {
        t0 = uint64(block.timestamp);
        uint256 id = _createDca(uint128(FILL_OUT));
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        book.setMaxFillDelay(0);
        vm.warp(t0 + 1 hours + 45 minutes);
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).filledCount, 2, "window disabled: any time inside expiry");
    }

    // ============================================================
    // INFO — DCA schedule drift
    // ============================================================

    /// Anchoring the next slot to when the fill LANDED made lateness compound: a 10-min-late fill
    /// used to push every remaining slot 10 min later, forever. The slot is now anchored to the
    /// schedule.
    function test_dca_scheduleDoesNotDriftAfterLateFill() public {
        t0 = uint64(block.timestamp);
        uint256 id = _createDca(uint128(FILL_OUT));

        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).nextFillTime, t0 + 1 hours, "slot 2 scheduled");

        // Keeper lands 10 min late (inside the 15-min window).
        vm.warp(t0 + 1 hours + 10 minutes);
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        // Pre-fix this was t0 + 2h + 10min and the drift compounded on every subsequent fill.
        assertEq(book.getOrder(id).nextFillTime, t0 + 2 hours, "schedule must not drift");
    }

    /// Clamp-forward: a fill that lands several intervals late must not leave a pile of due
    /// back-slots timestamped in the past.
    function test_dca_lateFill_clampsNextSlotForward() public {
        t0 = uint64(block.timestamp);
        uint256 id = _createDca(uint128(FILL_OUT));
        book.setMaxFillDelay(0); // isolate the drift behaviour from the window check

        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);

        vm.warp(t0 + 10 hours); // 9 intervals late
        vm.prank(keeper);
        book.executeFill(id, _routes1(address(tA), address(tB), FILL), NullOrderBook.RouteKind.Single);
        assertEq(book.getOrder(id).nextFillTime, t0 + 10 hours, "clamped to now, not left in the past");
    }

    // ============================================================
    // M8 — open-list growth
    // ============================================================

    function test_pruneExpired_removesOnlyExpiredIds() public {
        uint256 shortA = _createLimit(address(tA), address(tB), 1); // expiry +1d
        uint256 shortB = _createLimit(address(tA), address(tB), 1); // expiry +1d
        vm.prank(maker);
        uint256 longC = book.createOrder(
            address(tA), address(tB), FILL, 1, 1, 0, uint64(block.timestamp + 10 days), address(0)
        );
        assertEq(book.openOrderCount(), 3);

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (shortA, shortB, longC);

        // Nothing is expired yet → prune is a no-op, not a revert.
        assertEq(book.pruneExpired(ids), 0, "nothing prunable yet");
        assertEq(book.openOrderCount(), 3);

        vm.warp(block.timestamp + 2 days);
        assertEq(book.pruneExpired(ids), 2, "only the two expired ids");
        assertEq(book.openOrderCount(), 1, "live order survives");
        assertEq(book.openOrderIds()[0], longC, "swap-pop kept the right survivor");

        // Idempotent: a second sweep finds nothing left to remove.
        assertEq(book.pruneExpired(ids), 0);
    }

    /// Pruning must not touch escrow — the maker still gets a full refund afterwards.
    function test_pruneExpired_keepsMakerRefundable() public {
        uint256 id = _createLimit(address(tA), address(tB), 1);
        vm.warp(block.timestamp + 2 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        book.pruneExpired(ids);

        uint256 balBefore = tA.balanceOf(maker);
        vm.prank(maker);
        book.cancelOrder(id);
        assertEq(tA.balanceOf(maker) - balBefore, FILL, "escrow still refundable after prune");
    }

    /// The swap-pop is O(1) and must survive pruning from the middle of the array.
    function test_pruneExpired_swapPopIntegrity() public {
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = _createLimit(address(tA), address(tB), 1);

        // Mix both removal paths: cancel the first and last (normal swap-pop), then prune from the
        // middle of what's left. Pruning must not corrupt the index mapping either path relies on.
        vm.startPrank(maker);
        book.cancelOrder(ids[0]);
        book.cancelOrder(ids[4]);
        vm.stopPrank();
        assertEq(book.openOrderCount(), 3);

        vm.warp(block.timestamp + 2 days);
        uint256[] memory mid = new uint256[](1);
        mid[0] = ids[2];
        assertEq(book.pruneExpired(mid), 1);
        assertEq(book.openOrderCount(), 2);

        uint256[] memory open = book.openOrderIds();
        assertTrue(
            (open[0] == ids[1] || open[0] == ids[3]) && (open[1] == ids[1] || open[1] == ids[3]),
            "surviving ids intact"
        );
        assertTrue(open[0] != open[1], "no duplicate after swap-pop");
    }

    function test_pruneExpired_ignoresUnknownIds() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        assertEq(book.pruneExpired(ids), 0);
    }

    function test_create_enforcesMinNotionalWhenSet() public {
        book.setMinAmountPerFill(address(tA), 10 ether);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(NullOrderBook.BelowMinNotional.selector, uint128(1 ether), uint128(10 ether)));
        book.createOrder(address(tA), address(tB), 1 ether, 1, 1, 0, uint64(block.timestamp + 1 days), address(0));

        // Unset tokens keep the default: no minimum.
        vm.prank(maker);
        book.createOrder(address(tA), address(tB), 10 ether, 1, 1, 0, uint64(block.timestamp + 1 days), address(0));
    }

    function test_create_enforcesMaxOrderTtl() public {
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                NullOrderBook.ExpiryTooFar.selector, type(uint64).max, uint64(block.timestamp + 365 days)
            )
        );
        book.createOrder(
            address(tA), address(tB), FILL, 1, 1, 0, type(uint64).max, address(0)
        ); // squatting forever is what makes the open list un-prunable

        book.setMaxOrderTtl(0); // owner can opt out
        vm.prank(maker);
        book.createOrder(address(tA), address(tB), FILL, 1, 1, 0, type(uint64).max, address(0));
    }

    // ============================================================
    // Admin
    // ============================================================

    function test_setKeeper_onlyOwner() public {
        vm.prank(maker);
        vm.expectRevert();
        book.setKeeper(maker, true);
        book.setKeeper(address(0x1234), true);
        assertTrue(book.isKeeper(address(0x1234)));
        book.setKeeper(address(0x1234), false);
        assertFalse(book.isKeeper(address(0x1234)));
    }
}
