// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordLBPairAdapter} from "../../src/chord/ChordLBPairAdapter.sol";

interface IERC20LB {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ILBPairQ {
    function getSwapOut(uint128 amountIn, bool swapForY) external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
}

/// @notice Avalanche fork: the Chord LB pair adapter against Pharaoh DLMM's WAVAX/USDC bin-step-5 pair, both ways,
///         delivered == the pair's own `getSwapOut`. Run: AVAX_FORK_RPC=<url> forge test --match-contract LBPharaohForkTest
///         (excluded from CI with the other *ForkTest suites).
contract LBPharaohForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant PAIR = 0x8aC5707f8D4BDe1d771d34c7AfD81c3922b73379;

    ChordLBPairAdapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("AVAX_FORK_RPC"));
        address[] memory f = new address[](1);
        f[0] = FACTORY;
        adapter = new ChordLBPairAdapter(ROUTER, f);
    }

    function _swap(address tin, address tout, uint256 amt, address to) internal returns (uint256 out) {
        uint256 before = IERC20LB(tout).balanceOf(to);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, to, abi.encode(PAIR));
        assertEq(IERC20LB(tout).balanceOf(to) - before, out, "delivered != returned");
    }

    function test_wavaxUsdc_bothWays_matchGetSwapOut() public {
        address user = address(0xB0B);
        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = [uint256(1e17), 10e18, 500e18][i];
            deal(WAVAX, address(adapter), amt);
            (, uint128 q,) = ILBPairQ(PAIR).getSwapOut(uint128(amt), true);
            uint256 got = _swap(WAVAX, USDC, amt, user);
            console2.log("WAVAX in", amt, "USDC out", got);
            assertEq(got, q, "WAVAX->USDC != getSwapOut");
        }
        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = [uint256(1e6), 100e6, 5_000e6][i];
            deal(USDC, address(adapter), amt);
            (, uint128 q,) = ILBPairQ(PAIR).getSwapOut(uint128(amt), false);
            uint256 got = _swap(USDC, WAVAX, amt, user);
            console2.log("USDC in", amt, "WAVAX out", got);
            assertEq(got, q, "USDC->WAVAX != getSwapOut");
        }
    }
}
