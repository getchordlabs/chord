// SPDX-License-Identifier: UNLICENSED
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
contract MockFeeCollector {
    uint256 public lastFee;
    function feeBps() external pure returns (uint16) { return 5; }
    function collectFee(address, uint256 amount, address) external { lastFee = amount; }
}

/// Mints `amountIn` of tokenOut (1:1) to `to`; ignores the tokenIn it was sent.
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// A contract with no receive/fallback — rejects native MON, to test NativeTransferFailed.
contract NativeRejecter {
    function doSwap(NullRouter router, address tA, INullRouter.RouteStep calldata route, uint256 amt) external {
        MockERC20(tA).approve(address(router), type(uint256).max);
        router.swap(tA, address(0), amt, 0, block.timestamp + 1, route, address(0));
    }
}

/// Verifies the native-MON output fix: X->MON swaps unwrap WMON and deliver native MON.
contract NullRouterNativeOutTest is Test {
    NullRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockWMON wmon;
    MockFeeCollector fc;
    address _adp;
    address user = address(0xBEEF);
    uint256 constant AMT = 100 ether;

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        tC = new MockERC20();
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

        // WMON needs native backing so withdraw() can pay out.
        vm.deal(address(wmon), 1_000_000 ether);

        tA.mint(user, 1_000_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _single(address tin, address tout) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({adapter: _adp, tokenIn: tin, tokenOut: tout, amountIn: AMT, extraData: ""});
    }

    // ---- swap: tokenOut == address(0) delivers native MON, not WMON ----
    function test_swap_nativeOut_deliversNative() public {
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.swap(address(tA), address(0), AMT, 0, block.timestamp + 1, _single(address(tA), address(wmon)), address(0));
        assertGt(out, 0);
        assertEq(user.balance - before, out, "user must receive native MON == out");
        assertEq(wmon.balanceOf(user), 0, "user must NOT receive WMON");
    }

    // ---- backward-compat: tokenOut == WMON still delivers WMON, no native ----
    function test_swap_wmonOut_deliversWmon_backcompat() public {
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.swap(address(tA), address(wmon), AMT, 0, block.timestamp + 1, _single(address(tA), address(wmon)), address(0));
        assertEq(wmon.balanceOf(user), out, "user must receive WMON");
        assertEq(user.balance, before, "native balance unchanged");
    }

    // ---- splitSwap native output ----
    function test_splitSwap_nativeOut_deliversNative() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(wmon), AMT / 2, "");
        r[1] = INullRouter.RouteStep(_adp, address(tA), address(wmon), AMT / 2, "");
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.splitSwap(address(tA), address(0), AMT, 0, block.timestamp + 1, r, address(0));
        assertEq(user.balance - before, out, "split native output");
        assertEq(wmon.balanceOf(user), 0);
    }

    // ---- multiHopSwap native output (unwrapOutput=true) ----
    function test_multiHop_nativeOut_deliversNative() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(tB), AMT, "");
        r[1] = INullRouter.RouteStep(_adp, address(tB), address(wmon), 0, ""); // final hop -> WMON
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.multiHopSwap(AMT, 0, block.timestamp + 1, r, address(0), true);
        assertEq(user.balance - before, out, "multihop native output");
        assertEq(wmon.balanceOf(user), 0);
    }

    // ---- multiHop native output requires final hop == WMON ----
    function test_multiHop_nativeOut_nonWmonFinal_reverts() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(tB), AMT, "");
        r[1] = INullRouter.RouteStep(_adp, address(tB), address(tC), 0, ""); // final = tC, not WMON
        vm.prank(user);
        vm.expectRevert(NullRouter.InvalidRoute.selector);
        router.multiHopSwap(AMT, 0, block.timestamp + 1, r, address(0), true);
    }

    // ---- old multiHopSwap (no flag) still delivers the final ERC20 (backward-compat) ----
    function test_multiHop_noFlag_deliversToken_backcompat() public {
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep(_adp, address(tA), address(tB), AMT, "");
        r[1] = INullRouter.RouteStep(_adp, address(tB), address(tC), 0, "");
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.multiHopSwap(AMT, 0, block.timestamp + 1, r, address(0));
        assertEq(tC.balanceOf(user), out, "final token delivered");
        assertEq(user.balance, before, "no native");
    }

    // ---- recipient that rejects native MON -> NativeTransferFailed ----
    function test_nativeOut_recipientRejects_reverts() public {
        NativeRejecter bad = new NativeRejecter();
        tA.mint(address(bad), AMT);
        INullRouter.RouteStep memory route = INullRouter.RouteStep(_adp, address(tA), address(wmon), AMT, "");
        vm.expectRevert(NullRouter.NativeTransferFailed.selector);
        bad.doSwap(router, address(tA), route, AMT);
    }
}
