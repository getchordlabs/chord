// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniV3FactoryMin {
    function getPool(address, address, uint24) external view returns (address);
}

interface IRouterMin {
    function multiPathSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        INullRouter.Path[] calldata paths,
        address referrer
    ) external payable returns (uint256);
}

/// @notice Fork test for multiPathSwap: split the input across 2 independent paths
///         (1-hop direct + 2-hop detour), both through the generic V3 adapter, against
///         the LIVE proxy upgraded in-test to the new implementation.
contract MultiPathSwapForkTest is Test {
    // Mainnet
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a; // proxy
    address constant GENERIC = 0x681f6f5B13A7af251be4A2373a0D03118431Aac6; // UniV3GenericAdapter (approved)
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant PANGOLIN_WMON_AUSD = 0xcd00A33B65b1eaeaE1757c64eB79b94787A497A5;
    address constant UNI_V3_FACTORY = 0x204FAca1764B154221e35c0d20aBb3c525710498;

    address user = address(0xCAFE);

    function setUp() public {
        vm.createSelectFork("https://rpc.monad.xyz");
        // Upgrade the live proxy to the freshly-built implementation (UUPS, pranked as owner).
        address impl = deployCode("NullRouter.sol:NullRouter");
        address owner = 0x0f1171209dAD379AF0E486f2c77D275D6E0a4f79;
        vm.prank(owner);
        (bool ok,) = ROUTER.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, ""));
        require(ok, "upgrade failed");
    }

    function _pool(address a, address b) internal view returns (address p) {
        uint24[3] memory fees = [uint24(100), uint24(500), uint24(3000)];
        for (uint256 i = 0; i < 3; i++) {
            p = IUniV3FactoryMin(UNI_V3_FACTORY).getPool(a, b, fees[i]);
            if (p != address(0)) return p;
        }
        revert("no pool");
    }

    function _paths(uint256 aIn, uint256 bIn) internal view returns (INullRouter.Path[] memory paths) {
        paths = new INullRouter.Path[](2);
        // Path A: 1 hop, WMON -> AUSD direct on the Pangolin pool.
        INullRouter.RouteStep[] memory a = new INullRouter.RouteStep[](1);
        a[0] = INullRouter.RouteStep(GENERIC, WMON, AUSD, aIn, abi.encode(PANGOLIN_WMON_AUSD));
        paths[0] = INullRouter.Path(aIn, a);
        // Path B: 2 hops, WMON -> USDC -> AUSD via Uniswap V3 pools (generic adapter).
        INullRouter.RouteStep[] memory b = new INullRouter.RouteStep[](2);
        b[0] = INullRouter.RouteStep(GENERIC, WMON, USDC, bIn, abi.encode(_pool(WMON, USDC)));
        b[1] = INullRouter.RouteStep(GENERIC, USDC, AUSD, 0, abi.encode(_pool(USDC, AUSD)));
        paths[1] = INullRouter.Path(bIn, b);
    }

    function test_multiPath_erc20_in() public {
        deal(WMON, user, 10 ether);
        vm.startPrank(user);
        IERC20(WMON).approve(ROUTER, 10 ether);
        uint256 before = IERC20(AUSD).balanceOf(user);
        uint256 outAmt = IRouterMin(ROUTER).multiPathSwap(
            10 ether, 1, block.timestamp + 300, _paths(6 ether, 4 ether), address(0)
        );
        vm.stopPrank();
        assertGt(outAmt, 0, "no output");
        assertEq(IERC20(AUSD).balanceOf(user) - before, outAmt, "user credited != returned");
        // Router ends clean in every touched token.
        assertEq(IERC20(WMON).balanceOf(ROUTER), 0, "router WMON dust");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router USDC dust");
        assertEq(IERC20(AUSD).balanceOf(ROUTER), 0, "router AUSD dust");
    }

    function test_multiPath_native_in() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        uint256 outAmt = IRouterMin(ROUTER).multiPathSwap{value: 10 ether}(
            10 ether, 1, block.timestamp + 300, _paths(7 ether, 3 ether), address(0)
        );
        assertGt(outAmt, 0, "no output");
        assertEq(IERC20(WMON).balanceOf(ROUTER), 0, "router WMON dust");
    }

    function test_revert_sum_mismatch() public {
        deal(WMON, user, 10 ether);
        vm.startPrank(user);
        IERC20(WMON).approve(ROUTER, 10 ether);
        INullRouter.Path[] memory paths = _paths(6 ether, 3 ether); // declared 6+3 != 10
        vm.expectRevert();
        IRouterMin(ROUTER).multiPathSwap(10 ether, 1, block.timestamp + 300, paths, address(0));
        vm.stopPrank();
    }

    function test_revert_single_path() public {
        deal(WMON, user, 10 ether);
        vm.startPrank(user);
        IERC20(WMON).approve(ROUTER, 10 ether);
        INullRouter.Path[] memory one = new INullRouter.Path[](1);
        INullRouter.RouteStep[] memory a = new INullRouter.RouteStep[](1);
        a[0] = INullRouter.RouteStep(GENERIC, WMON, AUSD, 10 ether, abi.encode(PANGOLIN_WMON_AUSD));
        one[0] = INullRouter.Path(10 ether, a);
        vm.expectRevert();
        IRouterMin(ROUTER).multiPathSwap(10 ether, 1, block.timestamp + 300, one, address(0));
        vm.stopPrank();
    }

    function test_revert_exit_token_mismatch() public {
        deal(WMON, user, 10 ether);
        vm.startPrank(user);
        IERC20(WMON).approve(ROUTER, 10 ether);
        INullRouter.Path[] memory paths = _paths(6 ether, 4 ether);
        // Corrupt path B's exit token: last hop ends at USDC while path A ends at AUSD.
        INullRouter.RouteStep[] memory b = new INullRouter.RouteStep[](1);
        b[0] = INullRouter.RouteStep(GENERIC, WMON, USDC, 4 ether, abi.encode(_pool(WMON, USDC)));
        paths[1] = INullRouter.Path(4 ether, b);
        vm.expectRevert();
        IRouterMin(ROUTER).multiPathSwap(10 ether, 1, block.timestamp + 300, paths, address(0));
        vm.stopPrank();
    }
}
