// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

// ROUND 12 — the trust boundary the whole API leans on.
//
// The API deliberately does NOT vet what it encodes: round 3 pinned it as "the API is an encoder;
// AdapterRegistry's whitelist and the router's own checks are the security". This file tests THAT
// claim, because the boundary itself had no dedicated test file — NullRouter, AdapterRegistry,
// NullExecutor and NullBatch7702 were only covered incidentally.
//
// A failure here is not a bad quote. It is someone else's tokens.

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

contract MockFeeCollector {
    function feeBps() external pure returns (uint16) { return 5; }
    function feeBpsFor(address) external pure returns (uint16) { return 5; }
    function referralShareBps() external pure returns (uint16) { return 5000; }
    function collectFee(address, uint256, address) external {}
}

/// Pays out 1:1 — an honest adapter.
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// Pays out a fraction — models a sandwich / stale quote, i.e. what minOut exists to catch.
contract ShortfallAdapter {
    uint256 public numerator;
    constructor(uint256 n) { numerator = n; } // out = in * n / 100
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        uint256 out = (amountIn * numerator) / 100;
        MockERC20(tokenOut).mint(to, out);
        return out;
    }
}

contract NullRouterGuardsTest is Test {
    NullRouter router;
    AdapterRegistry registry;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 wmon;
    address honest;
    address rogue; // deployed but never whitelisted
    address user = address(0xBEEF);
    uint256 constant AMT = 100 ether;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        wmon = new MockERC20();
        MockFeeCollector fc = new MockFeeCollector();

        // A REAL AdapterRegistry (not the always-true mock other suites use) — the whitelist is
        // exactly what is under test here.
        AdapterRegistry regImpl = new AdapterRegistry();
        registry = AdapterRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(AdapterRegistry.initialize, (address(this)))))
        );

        honest = address(new MockAdapter());
        rogue = address(new MockAdapter());
        registry.addAdapter(honest);

        NullRouter impl = new NullRouter();
        router = NullRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            NullRouter.initialize,
                            (address(this), address(wmon), address(0), address(fc), address(registry))
                        )
                    )
                )
            )
        );

        tA.mint(user, 1_000_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _step(address adapter, uint256 amountIn) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({adapter: adapter, tokenIn: address(tA), tokenOut: address(tB), amountIn: amountIn, extraData: ""});
    }

    function _swap(address adapter, uint256 amountIn, uint256 minOut, uint256 deadline) internal {
        vm.prank(user);
        router.swap(address(tA), address(tB), amountIn, minOut, deadline, _step(adapter, amountIn), address(0));
    }

    // ── F1: the whitelist is the security, not the API ──────────────────────────────
    function test_unapprovedAdapterCannotBeUsed() public {
        // This is the exact calldata shape the API will happily encode for ANY adapter address
        // (round 3 asserted it does not vet them). The chain must be the one that says no.
        vm.expectRevert();
        _swap(rogue, AMT, 0, block.timestamp + 60);
    }

    function test_whitelistIsLiveNotSnapshotted() public {
        // Approve → works. Revoke → stops working immediately, without redeploying the router.
        registry.addAdapter(rogue);
        _swap(rogue, AMT, 0, block.timestamp + 60);
        assertGt(tB.balanceOf(user), 0, "an approved adapter should deliver");

        registry.removeAdapter(rogue);
        vm.expectRevert();
        _swap(rogue, AMT, 0, block.timestamp + 60);
    }

    // ── F2: only the owner writes the whitelist ─────────────────────────────────────
    function test_onlyOwnerCanChangeTheWhitelist() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert();
        registry.addAdapter(rogue);

        vm.prank(stranger);
        vm.expectRevert();
        registry.removeAdapter(honest);

        assertFalse(registry.isApproved(rogue), "a stranger must not be able to whitelist an adapter");
        assertTrue(registry.isApproved(honest), "a stranger must not be able to revoke one");
    }

    // ── F3: minOut is enforced on-chain ─────────────────────────────────────────────
    function test_minOutIsEnforcedWhenTheAdapterUnderdelivers() public {
        address short = address(new ShortfallAdapter(50)); // pays half
        registry.addAdapter(short);
        // Ask for the full amount out; the adapter can only produce 50%.
        vm.expectRevert();
        _swap(short, AMT, AMT, block.timestamp + 60);
        assertEq(tB.balanceOf(user), 0, "a reverted swap must leave the user with nothing new");
    }

    function test_minOutAtTheBoundaryPasses() public {
        address short = address(new ShortfallAdapter(50));
        registry.addAdapter(short);
        uint256 expected = AMT / 2;
        uint256 afterFee = expected - (expected * 5) / 10_000; // the router's 5bps default
        _swap(short, AMT, afterFee, block.timestamp + 60);
        assertGe(tB.balanceOf(user), afterFee, "a swap that exactly meets minOut must succeed");
    }

    // ── F4/F5: the cheap guards that keep junk out of adapters ──────────────────────
    function test_expiredDeadlineReverts() public {
        vm.warp(1_000_000);
        vm.expectRevert();
        _swap(honest, AMT, 0, block.timestamp - 1);
    }

    function test_zeroAmountReverts() public {
        vm.expectRevert();
        _swap(honest, 0, 0, block.timestamp + 60);
    }

    function test_routeMustMoveTheDeclaredPair() public {
        // The route says it sells tB while the function says tA — the shape round 3 showed the API
        // will encode verbatim. On-chain it must be InvalidRoute.
        INullRouter.RouteStep memory bad =
            INullRouter.RouteStep({adapter: honest, tokenIn: address(tB), tokenOut: address(tB), amountIn: AMT, extraData: ""});
        vm.prank(user);
        vm.expectRevert();
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 60, bad, address(0));
    }

    function test_routeMustConsumeExactlyAmountIn() public {
        // Round 4 started rejecting this at the API. Prove the chain rejects it too — defence in
        // depth, so an integrator calling the router directly cannot slip past it.
        vm.prank(user);
        vm.expectRevert();
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 60, _step(honest, AMT - 1), address(0));
    }

    // ── F7: multiPath share accounting ──────────────────────────────────────────────
    function test_multiPathSharesMustSumToAmountIn() public {
        INullRouter.Path[] memory paths = new INullRouter.Path[](2);
        INullRouter.RouteStep[] memory h1 = new INullRouter.RouteStep[](1);
        INullRouter.RouteStep[] memory h2 = new INullRouter.RouteStep[](1);
        h1[0] = _step(honest, 60 ether);
        h2[0] = _step(honest, 30 ether); // 90 total against a 100 declared input
        paths[0] = INullRouter.Path({amountIn: 60 ether, hops: h1});
        paths[1] = INullRouter.Path({amountIn: 30 ether, hops: h2});

        vm.prank(user);
        vm.expectRevert();
        router.multiPathSwap(AMT, 0, block.timestamp + 60, paths, address(0));
    }

    function test_multiPathRejectsAZeroShare() public {
        INullRouter.Path[] memory paths = new INullRouter.Path[](2);
        INullRouter.RouteStep[] memory h1 = new INullRouter.RouteStep[](1);
        INullRouter.RouteStep[] memory h2 = new INullRouter.RouteStep[](1);
        h1[0] = _step(honest, AMT);
        h2[0] = _step(honest, 0);
        paths[0] = INullRouter.Path({amountIn: AMT, hops: h1});
        paths[1] = INullRouter.Path({amountIn: 0, hops: h2});

        vm.prank(user);
        vm.expectRevert();
        router.multiPathSwap(AMT, 0, block.timestamp + 60, paths, address(0));
    }

    function test_multiPathNeedsAtLeastTwoPaths() public {
        INullRouter.Path[] memory paths = new INullRouter.Path[](1);
        INullRouter.RouteStep[] memory h1 = new INullRouter.RouteStep[](1);
        h1[0] = _step(honest, AMT);
        paths[0] = INullRouter.Path({amountIn: AMT, hops: h1});

        vm.prank(user);
        vm.expectRevert();
        router.multiPathSwap(AMT, 0, block.timestamp + 60, paths, address(0));
    }

    // ── F8: the user keeps everything except the fee ────────────────────────────────
    function test_userReceivesOutputMinusTheFeeOnly() public {
        _swap(honest, AMT, 0, block.timestamp + 60);
        uint256 fee = (AMT * 5) / 10_000; // 5bps default from the mock collector
        assertEq(tB.balanceOf(user), AMT - fee, "user must receive the full output minus exactly the fee");
        assertEq(tB.balanceOf(address(router)), 0, "the router must not retain output");
    }
}
