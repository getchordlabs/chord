// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordSolidlyAdapter} from "../../src/chord/ChordSolidlyAdapter.sol";

interface IERC20A {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IVeloPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

/// @notice Base fork: the Chord Solidly adapter against real Aerodrome V2 pools (factory `getPool`, no `getPair`) —
///         USDC/AERO volatile both ways, eUSD/USDC stable. Run: BASE_FORK_RPC=<url> forge test --match-contract
///         SolidlyAerodromeForkTest (excluded from CI with the other *ForkTest suites).
contract SolidlyAerodromeForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant USDC_AERO = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address constant EUSD_USDC = 0x7A034374C89C463DD65D8C9BCfe63BcBCED41f4F;
    address constant EUSD = 0xCfA3Ef56d303AE4fAabA0592388F19d7C3399FB4;

    ChordSolidlyAdapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_FORK_RPC"));
        address[] memory f = new address[](1);
        f[0] = FACTORY;
        adapter = new ChordSolidlyAdapter(ROUTER, f);
    }

    function _swap(address tin, address tout, uint256 amt, address pool, address to) internal returns (uint256 out) {
        uint256 before = IERC20A(tout).balanceOf(to);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, to, abi.encode(pool));
        assertEq(IERC20A(tout).balanceOf(to) - before, out, "delivered != returned");
    }

    function test_usdcAero_volatile_bothWays() public {
        address user = address(0xB0B);
        deal(USDC, address(adapter), 100e6);
        uint256 quoted = IVeloPool(USDC_AERO).getAmountOut(100e6, USDC);
        uint256 got = _swap(USDC, AERO, 100e6, USDC_AERO, user);
        console2.log("100 USDC -> AERO", got);
        assertEq(got, quoted);
        vm.prank(user);
        IERC20A(AERO).transfer(address(adapter), got);
        uint256 back = _swap(AERO, USDC, got, USDC_AERO, user);
        console2.log("AERO -> USDC back", back);
        assertGt(back, 100e6 * 99 / 100, "round trip kept < 99 %");
    }

    function test_eusdUsdc_stable() public {
        deal(USDC, address(adapter), 100e6);
        uint256 quoted = IVeloPool(EUSD_USDC).getAmountOut(100e6, USDC);
        uint256 got = _swap(USDC, EUSD, 100e6, EUSD_USDC, address(0xCAFE));
        console2.log("100 USDC -> eUSD", got);
        assertEq(got, quoted);
    }
}
