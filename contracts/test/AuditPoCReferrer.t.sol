// SPDX-License-Identifier: MIT
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

/// Models an INTERMEDIARY (GaslessEntry / order book / executor): it holds the user's tokens, calls
/// the router on their behalf, and forwards everything it received to the user. It declares its
/// principal through `currentSwapper()` — the opt-in ISwapperContext hook the router uses to resolve
/// the true beneficiary (H2, second defect: msg.sender is the intermediary, never the swapper).
contract RefIntermediary {
    NullRouter public immutable router;
    address public immutable adapter;
    address public currentSwapper; // ISwapperContext

    constructor(NullRouter r, address a) { router = r; adapter = a; }

    function relay(address tokenIn, address tokenOut, uint256 amt, address user, address referrer) external {
        currentSwapper = user;
        RefMockERC20(tokenIn).approve(address(router), amt);
        INullRouter.RouteStep memory r = INullRouter.RouteStep({
            adapter: adapter, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amt, extraData: ""
        });
        router.swap(tokenIn, tokenOut, amt, 0, block.timestamp + 1, r, referrer);
        currentSwapper = address(0);
        // Forward EVERYTHING that landed here — proceeds, dust sweep and (pre-fix) any referral
        // kickback — exactly as the real entries do.
        RefMockERC20(tokenOut).transfer(user, RefMockERC20(tokenOut).balanceOf(address(this)));
    }
}

/// An intermediary that does NOT implement the hook: the router must fall back to msg.sender and
/// must not revert on the failed staticcall.
contract RefDumbIntermediary {
    NullRouter public immutable router;
    address public immutable adapter;

    constructor(NullRouter r, address a) { router = r; adapter = a; }

    function relay(address tokenIn, address tokenOut, uint256 amt, address user, address referrer) external {
        RefMockERC20(tokenIn).approve(address(router), amt);
        INullRouter.RouteStep memory r = INullRouter.RouteStep({
            adapter: adapter, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amt, extraData: ""
        });
        router.swap(tokenIn, tokenOut, amt, 0, block.timestamp + 1, r, referrer);
        RefMockERC20(tokenOut).transfer(user, RefMockERC20(tokenOut).balanceOf(address(this)));
    }
}

/// H2 / L1 (2026-08-05 audit). The self-referral guard used to drop only `referrer == msg.sender`,
/// so it rejected neither the protocol's OWN addresses nor a contract-mediated swap's real
/// beneficiary. These run against the REAL NullRouter + FeeCollector + AdapterRegistry proxies at
/// mainnet fee settings (25 bps / 50% referral share) — no MockFeeCollector, which is precisely why
/// the rest of the suite never saw the leak.
///
/// The two original PoCs are kept and INVERTED: each asserted the leak, and now asserts it is gone.
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

    function _fullFee() internal pure returns (uint256) { return (AMT * FEE_BPS) / 10_000; }

    /// WAS the leak: naming the ROUTER as `referrer` rebated 50% of the protocol fee to the swapper
    /// (FeeCollector paid the referral half back into the router, whose dust sweep then forwarded it
    /// to msg.sender). Permissionless, one tx, no second wallet. Now the referrer is dropped.
    function test_fix_referrerIsRouter_noLongerRebates() public {
        _swap(honest, address(0));
        uint256 honestGot = tB.balanceOf(honest);
        uint256 treasuryFromHonest = fees.accumulatedFees(address(tB));

        _swap(attacker, address(router));
        uint256 attackerGot = tB.balanceOf(attacker);
        uint256 treasuryFromAttack = fees.accumulatedFees(address(tB)) - treasuryFromHonest;

        assertEq(honestGot, AMT - _fullFee(), "honest pays the full fee");
        assertEq(treasuryFromHonest, _fullFee(), "treasury keeps the full fee");

        assertEq(attackerGot, honestGot, "reflexive referrer must buy nothing");
        assertEq(treasuryFromAttack, _fullFee(), "treasury keeps the WHOLE fee, not half");
        assertEq(tB.balanceOf(address(router)), 0, "router still nets to zero");
    }

    /// WAS L1: naming the FEE COLLECTOR as `referrer` stranded half the fee — the referral transfer
    /// was a self-transfer (net no-op) that the ledger never booked. Now the referrer is dropped, so
    /// held == booked and nothing is stranded in the first place.
    function test_fix_referrerIsFeeCollector_noLongerStrands() public {
        _swap(attacker, address(fees));

        uint256 held = tB.balanceOf(address(fees));
        uint256 booked = fees.accumulatedFees(address(tB));

        assertEq(held, _fullFee(), "collector holds the whole fee");
        assertEq(booked, _fullFee(), "and the ledger books ALL of it");
        assertEq(held, booked, "nothing stranded outside the ledger");
    }

    /// L1 recovery path for what already stranded on the live proxy before the H2 fix shipped.
    /// Simulated by donating straight to the collector (identical end state: balance the ledger
    /// does not know about). withdrawFees pays from the ledger and cannot reach it.
    function test_fix_sweepUnaccounted_recoversTheStrandedHalf() public {
        _swap(honest, address(0));                 // books a real fee that must NOT be swept
        uint256 booked = fees.accumulatedFees(address(tB));
        assertGt(booked, 0, "setup: a booked fee exists");

        uint256 stranded = 7 ether;
        tB.mint(address(fees), stranded);          // arrives without ever being booked

        fees.sweepUnaccounted(address(tB), treasury);

        assertEq(tB.balanceOf(treasury), stranded, "exactly the unaccounted balance is recovered");
        assertEq(fees.accumulatedFees(address(tB)), booked, "booked fees are untouched");
        assertEq(tB.balanceOf(address(fees)), booked, "collector keeps exactly what it owes treasury");

        // Nothing left over → a second sweep has nothing to take.
        vm.expectRevert(bytes("NOTHING_UNACCOUNTED"));
        fees.sweepUnaccounted(address(tB), treasury);
    }

    function test_sweepUnaccounted_onlyOwner_andRejectsZeroTo() public {
        tB.mint(address(fees), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        fees.sweepUnaccounted(address(tB), attacker);

        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fees.sweepUnaccounted(address(tB), address(0));
    }

    /// H2, second defect. A contract-mediated swap (gasless entry / order book / executor) has
    /// msg.sender == the INTERMEDIARY, so `referrer == msg.sender` could never fire and an order
    /// could simply name its own user as referrer, clawing back half the fee via the intermediary's
    /// forward-everything payout. The router now resolves the declared swapper and drops it.
    function test_fix_contractMediatedSwap_cannotSelfRefer() public {
        RefIntermediary entry = new RefIntermediary(router, adp);
        tA.mint(address(entry), AMT * 2);

        // Baseline: an honest relayed swap with no referrer.
        entry.relay(address(tA), address(tB), AMT, honest, address(0));
        uint256 honestGot = tB.balanceOf(honest);
        assertEq(honestGot, AMT - _fullFee(), "relayed swap pays the full fee");

        // Attack: the order names its own user as referrer.
        uint256 bookedBefore = fees.accumulatedFees(address(tB));
        entry.relay(address(tA), address(tB), AMT, attacker, attacker);
        assertEq(tB.balanceOf(attacker), honestGot, "self-referral through an intermediary buys nothing");
        assertEq(
            fees.accumulatedFees(address(tB)) - bookedBefore, _fullFee(), "treasury keeps the whole fee"
        );
        assertEq(tB.balanceOf(address(entry)), 0, "no kickback stuck in the intermediary");
    }

    /// The intermediary itself as referrer is equally reflexive: it forwards its whole balance to
    /// the user, so a kickback to the caller is a kickback to the swapper.
    function test_fix_contractMediatedSwap_intermediaryAsReferrerDropped() public {
        RefIntermediary entry = new RefIntermediary(router, adp);
        tA.mint(address(entry), AMT);

        entry.relay(address(tA), address(tB), AMT, attacker, address(entry));
        assertEq(tB.balanceOf(attacker), AMT - _fullFee(), "no rebate via referrer == the caller");
        assertEq(fees.accumulatedFees(address(tB)), _fullFee(), "treasury keeps the whole fee");
    }

    /// A caller that does not implement the hook must still work (staticcall failure is swallowed)
    /// and must still get the msg.sender guard, while a genuine third-party referrer is untouched.
    function test_hookAbsent_fallsBackToMsgSender_andThirdPartyReferralSurvives() public {
        RefDumbIntermediary dumb = new RefDumbIntermediary(router, adp);
        tA.mint(address(dumb), AMT * 2);

        // No hook, referrer == the caller → dropped by the msg.sender arm of the guard.
        dumb.relay(address(tA), address(tB), AMT, honest, address(dumb));
        assertEq(fees.accumulatedFees(address(tB)), _fullFee(), "treasury keeps the whole fee");

        // A real third party still earns its referral share.
        address partner = address(0xF00D);
        uint256 bookedBefore = fees.accumulatedFees(address(tB));
        dumb.relay(address(tA), address(tB), AMT, honest, partner);
        assertEq(tB.balanceOf(partner), _fullFee() / 2, "third-party referrer still paid");
        assertEq(fees.accumulatedFees(address(tB)) - bookedBefore, _fullFee() / 2, "treasury keeps the rest");
    }

    /// A direct user naming themselves — the case the original guard covered — must still be dropped.
    function test_fix_directSelfReferral_stillDropped() public {
        _swap(attacker, attacker);
        assertEq(tB.balanceOf(attacker), AMT - _fullFee(), "self-referral buys nothing");
        assertEq(fees.accumulatedFees(address(tB)), _fullFee(), "treasury keeps the whole fee");
    }
}
