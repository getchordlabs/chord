// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";

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

contract MockRegistry {
    function isApproved(address) external pure returns (bool) { return true; }
}

/// Records the referrer the router forwards, so tests can assert self-referral is dropped.
/// Also models per-token tiered fees: feeBpsFor(token) returns an override if set, else the 5bps default.
contract MockFeeCollector {
    address public lastReferrer = address(0xDEAD);
    uint256 public lastFee;
    mapping(address => uint16) public overrideBps; // token → bps (0 = use default)
    function feeBps() external pure returns (uint16) { return 5; }
    function feeBpsFor(address token) external view returns (uint16) {
        uint16 o = overrideBps[token];
        return o == 0 ? 5 : o;
    }
    function setOverride(address token, uint16 bps) external { overrideBps[token] = bps; }
    function referralShareBps() external pure returns (uint16) { return 5000; }
    function collectFee(address, uint256 amount, address referrer) external { lastReferrer = referrer; lastFee = amount; }
}

/// Mints `amountIn` of tokenOut (1:1) to `to`; ignores the tokenIn it was sent.
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// Verifies the 3 contracts-core audit fixes: multi-hop token chaining, self-referral drop, native-on-ERC20 revert.
contract NullRouterFixesTest is Test {
    NullRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockERC20 wmon;
    MockFeeCollector fc;
    address user = address(0xBEEF);
    uint256 constant AMT = 100 ether;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        tC = new MockERC20();
        wmon = new MockERC20();
        fc = new MockFeeCollector();
        MockRegistry reg = new MockRegistry();
        MockAdapter adp = new MockAdapter();
        _adp = address(adp);

        NullRouter impl = new NullRouter();
        bytes memory initData = abi.encodeCall(
            NullRouter.initialize,
            (address(this), address(wmon), address(0), address(fc), address(reg))
        );
        router = NullRouter(payable(address(new ERC1967Proxy(address(impl), initData))));

        tA.mint(user, 1_000_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    address _adp;

    function _single(address tin, address tout) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({adapter: _adp, tokenIn: tin, tokenOut: tout, amountIn: AMT, extraData: ""});
    }

    // ---- Fix #1: multi-hop hop continuity (routes[i].tokenIn == routes[i-1].tokenOut) ----
    function test_multiHop_tokenMismatch_reverts() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(tB), AMT, "");
        r[1] = INullRouter.RouteStep(_adp, address(tC), address(tB), 0, ""); // tokenIn=tC != prior tokenOut=tB
        vm.prank(user);
        vm.expectRevert(bytes("HOP_TOKEN_MISMATCH"));
        router.multiHopSwap(AMT, 0, block.timestamp + 1, r, address(0));
    }

    function test_multiHop_validChain_succeeds() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(tB), AMT, "");
        r[1] = INullRouter.RouteStep(_adp, address(tB), address(tC), 0, ""); // properly chained
        vm.prank(user);
        uint256 out = router.multiHopSwap(AMT, 0, block.timestamp + 1, r, address(0));
        assertGt(out, 0, "valid chain should produce output");
    }

    // ---- Tiered fee: router charges feeBpsFor(OUTPUT token) ----
    function test_tieredFee_defaultUnchanged_thenTieredOnOutput() public {
        // Default (no override) → 5 bps on output token tB (behaviour-preserving regression).
        vm.prank(user);
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), address(0));
        assertEq(fc.lastFee(), (AMT * 5) / 10000, "default must stay 5bps");

        // Set a 30 bps override on tB → a swap whose OUTPUT is tB now pays the meme tier.
        fc.setOverride(address(tB), 30);
        vm.prank(user);
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), address(0));
        assertEq(fc.lastFee(), (AMT * 30) / 10000, "output tB should pay 30bps");

        // A token with no override is unaffected → cheap-exit direction stays 5bps.
        assertEq(fc.feeBpsFor(address(tC)), 5, "untiered token stays default");
    }

    // ---- Fix #2: self-referral dropped, third-party kept ----
    function test_selfReferral_dropped() public {
        vm.prank(user);
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), user);
        assertEq(fc.lastReferrer(), address(0), "self-referral must be dropped to address(0)");
        assertGt(fc.lastFee(), 0, "fee should have been collected");
    }

    function test_thirdPartyReferral_kept() public {
        address ref = address(0xCAFE);
        vm.prank(user);
        router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), ref);
        assertEq(fc.lastReferrer(), ref, "third-party referrer must be kept");
    }

    // ---- Fix #3: native value attached to an ERC20 swap reverts (no silent stuck MON) ----
    function test_nativeValue_onERC20_reverts() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes("UNEXPECTED_VALUE"));
        router.swap{value: 1 ether}(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), address(0));
    }

    function test_erc20Swap_noValue_succeeds() public {
        vm.prank(user);
        uint256 out = router.swap(address(tA), address(tB), AMT, 0, block.timestamp + 1, _single(address(tA), address(tB)), address(0));
        assertGt(out, 0, "ERC20 swap with no value should succeed");
    }
}
