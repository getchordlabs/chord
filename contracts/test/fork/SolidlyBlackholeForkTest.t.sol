// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordSolidlyAdapter} from "../../src/chord/ChordSolidlyAdapter.sol";

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ISolidlyPairF {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

/// @notice Avalanche fork: the Chord Solidly adapter against real Blackhole V1 pairs — SUPER/USDC (volatile,
///         70 bps) both ways, and USDC/EURC (stable). Run: AVAX_FORK_RPC=<url> forge test --match-contract
///         SolidlyBlackholeForkTest (excluded from CI with the other *ForkTest suites).
contract SolidlyBlackholeForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant FACTORY = 0xfE926062Fb99CA5653080d6C14fE945Ad68c265C;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant SUPER = 0x09Fa58228bB791ea355c90DA1e4783452b9Bd8C3;
    address constant EURC = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD;
    address constant SUPER_USDC = 0x9d848CF080c46b92B797218835aE7E89e04c1515;
    address constant USDC_EURC = 0x65f83CCacaBaAC4eD2f80289A02dF4D35d744aE8;

    ChordSolidlyAdapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("AVAX_FORK_RPC"));
        address[] memory f = new address[](1);
        f[0] = FACTORY;
        adapter = new ChordSolidlyAdapter(ROUTER, f);
    }

    function _swap(address tin, address tout, uint256 amt, address pool, address to) internal returns (uint256 out) {
        uint256 before = IERC20F(tout).balanceOf(to);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, to, abi.encode(pool));
        assertEq(IERC20F(tout).balanceOf(to) - before, out, "delivered != returned");
    }

    function test_superUsdc_volatile_bothWays() public {
        address user = address(0xB0B);
        deal(USDC, address(adapter), 10e6);
        uint256 quoted = ISolidlyPairF(SUPER_USDC).getAmountOut(10e6, USDC);
        uint256 got = _swap(USDC, SUPER, 10e6, SUPER_USDC, user);
        console2.log("10 USDC -> SUPER", got, "quoted", quoted);
        assertEq(got, quoted);

        // Sell-ability: the user moves SUPER on (as the router would pull it), then it sells back.
        vm.prank(user);
        IERC20F(SUPER).transfer(address(adapter), got);
        uint256 back = _swap(SUPER, USDC, got, SUPER_USDC, user);
        console2.log("SUPER -> USDC back", back);
        assertGt(back, 10e6 * 98 / 100, "round trip kept < 98 %");
    }

    function test_usdcEurc_stable() public {
        deal(USDC, address(adapter), 100e6);
        uint256 quoted = ISolidlyPairF(USDC_EURC).getAmountOut(100e6, USDC);
        uint256 got = _swap(USDC, EURC, 100e6, USDC_EURC, address(0xCAFE));
        console2.log("100 USDC -> EURC", got);
        assertEq(got, quoted);
    }
}
