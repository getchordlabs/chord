// SPDX-License-Identifier: UNLICENSED
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
    function collectFee(address, uint256 amount, address referrer) external { lastReferrer = referrer; lastFee = amount; }
}

/// Mints `amountIn` of tokenOut (1:1) to `to`; ignores the tokenIn it was sent.
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

contract NullOrderBookTest is Test {
    NullRouter router;
    NullOrderBook book;
    MockERC20 tA;
    MockERC20 tB;
    MockWMON wmon;
    MockFeeCollector fc;
    address _adp;

    address maker = address(0xBEEF);
    address keeper = address(0xCAFE);
    address referrer = address(0xFEE5);

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
