// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordAlgebraIntegralAdapter} from "../../src/chord/ChordAlgebraIntegralAdapter.sol";
import {AlgebraIntegralAdapter} from "../../src/adapters/AlgebraIntegralAdapter.sol";
import {IntegralQuoteProbe} from "../../src/probes/IntegralQuoteProbe.sol";

interface IIntegralPoolTokens {
    function token0() external view returns (address);
}

interface IERC20AI {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Forks of the three Algebra Integral deployments the Chord adapter targets — Blackhole CL WAVAX/USDC on
///         Avalanche (custom pool deployer), Hydrex + QuickSwap V4 on Base, THENA V3 on BNB — each both ways, delivered
///         == returned, round trip kept within the pool fees. Run with AVAX_FORK_RPC / BASE_FORK_RPC / BNB_FORK_RPC
///         (excluded from CI with the other *ForkTest suites).
contract AlgebraIntegralForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;

    function _adapter(address f0, address d0, address f1, address d1) internal returns (ChordAlgebraIntegralAdapter) {
        uint256 n = f1 == address(0) ? 1 : 2;
        address[] memory fs = new address[](n);
        address[] memory ds = new address[](n);
        fs[0] = f0; ds[0] = d0;
        if (n == 2) { fs[1] = f1; ds[1] = d1; }
        return new ChordAlgebraIntegralAdapter(ROUTER, fs, ds);
    }

    function _roundTrip(ChordAlgebraIntegralAdapter a, address pool, address tin, address tout, uint256 amt, uint256 minKeptBps)
        internal
    {
        address user = address(0xB0B);
        // The engine's quote: the probe's simulated swap must equal what the adapter then delivers.
        IntegralQuoteProbe probe = new IntegralQuoteProbe();
        bool z = IIntegralPoolTokens(pool).token0() == tin;
        (int256 q0, int256 q1) = probe.quote(pool, z, int256(amt));
        uint256 quoted = uint256(-(z ? q1 : q0));
        deal(tin, address(a), amt);
        uint256 b0 = IERC20AI(tout).balanceOf(user);
        vm.prank(ROUTER);
        uint256 got = a.swap(tin, tout, amt, user, abi.encode(pool));
        assertEq(IERC20AI(tout).balanceOf(user) - b0, got, "delivered != returned");
        assertEq(got, quoted, "delivered != probe quote");
        vm.prank(user);
        IERC20AI(tout).transfer(address(a), got);
        uint256 c0 = IERC20AI(tin).balanceOf(user);
        vm.prank(ROUTER);
        uint256 back = a.swap(tout, tin, got, user, abi.encode(pool));
        assertEq(IERC20AI(tin).balanceOf(user) - c0, back, "delivered != returned (back)");
        console2.log("in", amt, "out", got);
        console2.log("back", back, "kept bps", back * 10_000 / amt);
        assertGe(back * 10_000 / amt, minKeptBps, "round trip kept too little");
    }

    function test_blackholeCL_avax_customDeployer() public {
        vm.createSelectFork(vm.envString("AVAX_FORK_RPC"));
        ChordAlgebraIntegralAdapter a = _adapter(
            0x512eb749541B7cf294be882D636218c84a5e9E5F, 0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584, address(0), address(0)
        );
        _roundTrip(a, 0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7, 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
            0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, 100e6, 9_850);
        // the same pool is NOT a default pool — an adapter pinned only to poolByPair refuses it
        ChordAlgebraIntegralAdapter d = _adapter(0x512eb749541B7cf294be882D636218c84a5e9E5F, address(0), address(0), address(0));
        deal(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, address(d), 1e6);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(AlgebraIntegralAdapter.PoolNotRegistered.selector, 0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7));
        d.swap(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, 1e6, address(0xB0B),
            abi.encode(0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7));
    }

    function test_hydrexAndQuickswapV4_base() public {
        vm.createSelectFork(vm.envString("BASE_FORK_RPC"));
        ChordAlgebraIntegralAdapter a = _adapter(
            0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E, address(0), 0xC5396866754799B9720125B104AE01d935Ab9C7b, address(0)
        );
        // Hydrex: token0 0x2Ae3F1Ec… / WETH
        _roundTrip(a, 0xB1383DC47D9971Fc999C3A9088F79E744b376e97, 0x4200000000000000000000000000000000000006,
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22, 0.01 ether, 9_800);
        // QuickSwap V4: WETH / USDC
        _roundTrip(a, 0x5a9Ad2BB92B0B3E5C571FDD5125114E04E02be1a, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            0x4200000000000000000000000000000000000006, 20e6, 9_850);
    }

    function test_thenaV3_bnb() public {
        vm.createSelectFork(vm.envString("BNB_FORK_RPC"));
        ChordAlgebraIntegralAdapter a = _adapter(0x30055F87716d3DFD0E5198C27024481099fB4A98, address(0), address(0), address(0));
        // THENA V3: ETH / WBNB
        _roundTrip(a, 0x58F04AAda1051885a3C4e296aaB0A454Ea1233A3, 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            0x2170Ed0880ac9A755fd29B2688956BD959F933F8, 0.02 ether, 9_800);
    }
}
