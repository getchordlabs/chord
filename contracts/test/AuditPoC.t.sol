// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";

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

/// Burns 1% on every transfer — the fee-on-transfer OUTPUT token that used to fail every route
/// (plan.md blocker): the router transferred out the pre-tax number it had been told about, which it
/// never actually held.
contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "BAL");
        uint256 tax = a / 100;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a - tax; // the tax is burnt
        return true;
    }
}

contract MockRegistry {
    function isApproved(address) external pure returns (bool) { return true; }
}

contract MockFeeCollector {
    function feeBpsFor(address) external pure returns (uint16) { return 0; }
    function collectFee(address, uint256, address) external {}
}

/// Adapter that DELIVERS less than it REPORTS — models a hostile pool named in extraData (H1) or an
/// over-reporting/buggy whitelisted adapter.
contract OverReportingAdapter {
    uint256 public shortfall;
    constructor(uint256 s) { shortfall = s; }
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn - shortfall); // delivers less...
        return amountIn;                                    // ...but reports the full amount
    }
}

/// Honest 1:1 adapter.
contract HonestAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// Pays out through a REAL transfer of a taxing token, so the router receives less than the adapter
/// reports without the adapter lying about anything.
contract FotAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        FeeOnTransferERC20(tokenOut).mint(address(this), amountIn);
        FeeOnTransferERC20(tokenOut).transfer(to, amountIn);
        return amountIn; // pre-tax — what every real DEX quoter reports
    }
}

/// M1 (2026-08-05 audit). The H1 dust-baseline guard stops a swapper from SWEEPING the router's
/// standing balance, but _settleOutput used to SPEND it: fee and payout were computed from the
/// adapter's self-reported return rather than a measured balance delta, so a shortfall was silently
/// covered from whatever the router already held (post-settlement balance BELOW baseline →
/// _sweepDustDelta a no-op → nothing reverted).
///
/// The original PoC is kept and INVERTED — it asserted the subsidy, and now asserts it is gone.
contract AuditPoCTest is Test {
    NullRouter router;
    MockERC20 tA;
    MockERC20 tB;
    address user = address(0xBEEF);
    address adapter;
    address honest;
    uint256 constant AMT = 100 ether;
    uint256 constant SHORTFALL = 10 ether;
    uint256 constant DONATION = 50 ether;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        MockFeeCollector fc = new MockFeeCollector();
        MockRegistry reg = new MockRegistry();
        adapter = address(new OverReportingAdapter(SHORTFALL));
        honest = address(new HonestAdapter());

        NullRouter impl = new NullRouter();
        router = NullRouter(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NullRouter.initialize, (address(this), address(0x1234), address(0), address(fc), address(reg)))
        ))));

        tA.mint(user, 1_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _step(address adp, address tin, address tout, uint256 amt)
        internal
        pure
        returns (INullRouter.RouteStep memory)
    {
        return INullRouter.RouteStep({adapter: adp, tokenIn: tin, tokenOut: tout, amountIn: amt, extraData: ""});
    }

    /// The user is now paid what the swap actually DELIVERED, and the router's standing balance is
    /// never touched. Pre-fix: the user was paid the reported 100 and the donation dropped to 40.
    function test_fix_standingBalanceNoLongerSubsidisesShortfall() public {
        tB.mint(address(router), DONATION);

        vm.prank(user);
        uint256 got = router.swap(
            address(tA), address(tB), AMT, 0, block.timestamp + 1, _step(adapter, address(tA), address(tB), AMT), address(0)
        );

        assertEq(got, AMT - SHORTFALL, "settled on the MEASURED delta, not the adapter's claim");
        assertEq(tB.balanceOf(user), AMT - SHORTFALL, "user receives exactly what the swap produced");
        assertEq(tB.balanceOf(address(router)), DONATION, "standing balance untouched");
    }

    /// With a realistic minOut (the quoted amount), an under-delivering adapter now REVERTS instead
    /// of being topped up out of the router's balance. Pre-fix this swap succeeded, silently.
    function test_fix_underDeliveringAdapter_revertsAgainstQuotedMinOut() public {
        tB.mint(address(router), DONATION);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(NullRouter.InsufficientOutput.selector, AMT - SHORTFALL, AMT)
        );
        router.swap(
            address(tA), address(tB), AMT, AMT, block.timestamp + 1, _step(adapter, address(tA), address(tB), AMT), address(0)
        );

        assertEq(tB.balanceOf(address(router)), DONATION, "reverted swap leaves the donation alone");
        assertEq(tB.balanceOf(user), 0, "and pays the user nothing");
    }

    /// multiPathSwap amplification: earlier paths' proceeds sit in the router while later paths run,
    /// so an over-reporting later path borrowed them and the swap completed silently — no revert,
    /// even without any donation. Now the shortfall shows up in the settled total.
    function test_fix_multiPathShortfallNoLongerBorrowsEarlierProceeds() public {
        INullRouter.Path[] memory paths = new INullRouter.Path[](2);
        INullRouter.RouteStep[] memory h1 = new INullRouter.RouteStep[](1);
        INullRouter.RouteStep[] memory h2 = new INullRouter.RouteStep[](1);
        h1[0] = _step(honest, address(tA), address(tB), 60 ether);
        h2[0] = _step(adapter, address(tA), address(tB), 40 ether); // reports 40, delivers 30
        paths[0] = INullRouter.Path({amountIn: 60 ether, hops: h1});
        paths[1] = INullRouter.Path({amountIn: 40 ether, hops: h2});

        // Asking for the full quoted 100 must now fail — pre-fix it succeeded by paying the user out
        // of path A's proceeds.
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(NullRouter.InsufficientOutput.selector, AMT - SHORTFALL, AMT)
        );
        router.multiPathSwap(AMT, AMT, block.timestamp + 1, paths, address(0));

        // And with an honest minOut it settles on the measured 90.
        vm.prank(user);
        uint256 got = router.multiPathSwap(AMT, AMT - SHORTFALL, block.timestamp + 1, paths, address(0));
        assertEq(got, AMT - SHORTFALL, "multi-path settles on measured output");
        assertEq(tB.balanceOf(address(router)), 0, "router keeps nothing");
    }

    /// Fee-on-transfer OUTPUT tokens (the live blocker in plan.md). Pre-fix the router tried to
    /// transfer the pre-tax amount it never held → every route through such a token reverted.
    function test_fix_feeOnTransferOutputTokenNowRoutes() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        address fotAdp = address(new FotAdapter());

        vm.prank(user);
        uint256 got = router.swap(
            address(tA), address(fot), AMT, 0, block.timestamp + 1, _step(fotAdp, address(tA), address(fot), AMT), address(0)
        );

        uint256 landed = AMT - AMT / 100;                 // what the router actually received
        assertEq(got, landed, "settled on what landed, not the pre-tax quote");
        assertEq(fot.balanceOf(user), landed - landed / 100, "user credited, minus their own transfer tax");
        assertEq(fot.balanceOf(address(router)), 0, "router keeps nothing");
    }
}
