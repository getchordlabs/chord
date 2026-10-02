// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {InfinityPoolKey} from "../../src/adapters/PancakeInfinityCLAdapter.sol";
import {ChordInfinityCLAdapter} from "../../src/chord/ChordInfinityCLAdapter.sol";

interface IERC20I {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ICLQuoterI {
    struct QuoteExactSingleParams {
        InfinityPoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice BNB Chain fork: the Chord Infinity CL adapter against the real PancakeSwap Infinity Vault — a vanilla pool
///         (native BNB / USDT, hooks = 0) both ways, and the CNPY / USDT pool whose hook runs beforeSwap (quote must
///         equal execution, CNPY must move without a transfer tax and sell back). Every fill is compared to CLQuoter
///         at the same block. Run: BNB_FORK_RPC=<archive url> forge test --match-contract InfinityCLBnbForkTest -vv
///         (excluded from CI with the other *ForkTest suites).
contract InfinityCLBnbForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant CL_QUOTER = 0xd0737C9762912dD34c3271197E362Aa736Df0926;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant CNPY = 0xC69B16CF18CEA1e5D0bb6a1a9db802097790dDD2;
    address constant CNPY_HOOK = 0xb0BAa371b899950B4Ef6A27c21bAf5ef7c434d0f;
    address constant USER = address(0xB0B);

    ChordInfinityCLAdapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("BNB_FORK_RPC"));
        adapter = new ChordInfinityCLAdapter(ROUTER, VAULT, CL_POOL_MANAGER, WBNB);
    }

    /// @dev pool 0xd37aa0f0… — native BNB / USDT, fee 67 (0.0067 %), tickSpacing 1, no hooks.
    function _bnbUsdt() internal pure returns (InfinityPoolKey memory) {
        return InfinityPoolKey(address(0), USDT, address(0), CL_POOL_MANAGER, 67, bytes32(uint256(1) << 16));
    }

    /// @dev pool 0xc7bb4cf4… — USDT / CNPY, fee 67, tickSpacing 10, hook bitmap 0x45 (beforeInitialize,
    ///      beforeAddLiquidity, beforeSwap).
    function _usdtCnpy() internal pure returns (InfinityPoolKey memory) {
        return InfinityPoolKey(USDT, CNPY, CNPY_HOOK, CL_POOL_MANAGER, 67, bytes32(uint256(0x0a0045)));
    }

    function _quote(InfinityPoolKey memory k, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (out,) = ICLQuoterI(CL_QUOTER).quoteExactInputSingle(
            ICLQuoterI.QuoteExactSingleParams(k, zeroForOne, uint128(amt), "")
        );
    }

    function _swap(address tin, address tout, uint256 amt, InfinityPoolKey memory k) internal returns (uint256 out) {
        uint256 before = IERC20I(tout).balanceOf(USER);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, USER, abi.encode(k));
        assertEq(IERC20I(tout).balanceOf(USER) - before, out, "delivered != returned");
        assertEq(IERC20I(tin).balanceOf(address(adapter)), 0, "input left in the adapter");
    }

    /// @dev Moves `amt` of `token` from USER to the adapter (as the router would) and returns what arrived.
    function _handToAdapter(address token, uint256 amt) internal returns (uint256 arrived) {
        uint256 b0 = IERC20I(token).balanceOf(address(adapter));
        vm.prank(USER);
        IERC20I(token).transfer(address(adapter), amt);
        arrived = IERC20I(token).balanceOf(address(adapter)) - b0;
    }

    function test_vanilla_nativeBnbUsdt_bothWays_equalsQuoter() public {
        deal(WBNB, address(adapter), 0.05 ether);
        uint256 q = _quote(_bnbUsdt(), true, 0.05 ether);
        uint256 usdt = _swap(WBNB, USDT, 0.05 ether, _bnbUsdt());
        console2.log("0.05 BNB -> USDT", usdt, "quoter", q);
        assertEq(usdt, q);

        _handToAdapter(USDT, usdt);
        uint256 q2 = _quote(_bnbUsdt(), false, usdt);
        uint256 bnb = _swap(USDT, WBNB, usdt, _bnbUsdt());
        console2.log("USDT -> WBNB back", bnb, "quoter", q2);
        assertEq(bnb, q2);
        assertGt(bnb, 0.05 ether * 999 / 1000, "round trip kept < 99.9 %");
    }

    function test_hookPool_usdtCnpy_bothWays_equalsQuoter_noTax() public {
        deal(USDT, address(adapter), 5e18);
        uint256 q = _quote(_usdtCnpy(), true, 5e18);
        uint256 cnpy = _swap(USDT, CNPY, 5e18, _usdtCnpy());
        console2.log("5 USDT -> CNPY", cnpy, "quoter", q);
        assertEq(cnpy, q, "beforeSwap hook: execution != quote");

        uint256 arrived = _handToAdapter(CNPY, cnpy);
        assertEq(arrived, cnpy, "CNPY transfer is taxed");
        uint256 q2 = _quote(_usdtCnpy(), false, cnpy);
        uint256 back = _swap(CNPY, USDT, cnpy, _usdtCnpy());
        console2.log("CNPY -> USDT back", back, "quoter", q2);
        assertEq(back, q2, "beforeSwap hook: execution != quote (sell)");
        assertGt(back, 5e18 * 98 / 100, "round trip kept < 98 %");
    }
}
