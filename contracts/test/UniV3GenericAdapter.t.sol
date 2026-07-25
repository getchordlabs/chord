// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV3GenericAdapter} from "../src/adapters/UniV3GenericAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork test: the generic V3 adapter must fill a real Pangolin V3 pool BOTH directions via the
///         direct pool.swap + callback path (no per-fork router). Pangolin is a standard Uniswap V3 fork
///         (uniswapV3SwapCallback), so this exercises the named-callback path.
contract UniV3GenericAdapterForkTest is Test {
    UniV3GenericAdapter adapter;

    // Monad mainnet
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    // PangolinV3 WMON/AUSD pool (token0 = AUSD, token1 = WMON), factory 0x44805F92…
    address constant POOL = 0xcd00A33B65b1eaeaE1757c64eB79b94787A497A5;

    address recipient = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork("https://rpc.monad.xyz");
        adapter = new UniV3GenericAdapter();
    }

    function test_pangolin_WMON_to_AUSD() public {
        uint256 amountIn = 10 ether; // 10 WMON
        deal(WMON, address(adapter), amountIn); // simulate NullRouter's PUSH

        uint256 before = IERC20(AUSD).balanceOf(recipient);
        uint256 out = adapter.swap(WMON, AUSD, amountIn, recipient, abi.encode(POOL));

        assertGt(out, 0, "no output");
        assertEq(IERC20(AUSD).balanceOf(recipient) - before, out, "recipient credited != returned");
        assertEq(IERC20(WMON).balanceOf(address(adapter)), 0, "adapter leaked WMON");
        assertEq(IERC20(AUSD).balanceOf(address(adapter)), 0, "adapter kept AUSD");
    }

    function test_pangolin_AUSD_to_WMON() public {
        // deal() can't write AUSD's (non-standard) balance slot, so SOURCE AUSD from a forward swap
        // first — this also exercises the zeroForOne=true path (AUSD is token0 of this pool).
        deal(WMON, address(adapter), 10 ether);
        uint256 ausd = adapter.swap(WMON, AUSD, 10 ether, address(this), abi.encode(POOL));
        assertGt(ausd, 0, "seed swap gave no AUSD");

        IERC20(AUSD).transfer(address(adapter), ausd); // simulate NullRouter's PUSH
        uint256 before = IERC20(WMON).balanceOf(recipient);
        uint256 out = adapter.swap(AUSD, WMON, ausd, recipient, abi.encode(POOL));

        assertGt(out, 0, "no output");
        assertEq(IERC20(WMON).balanceOf(recipient) - before, out, "recipient credited != returned");
        assertEq(IERC20(AUSD).balanceOf(address(adapter)), 0, "adapter leaked AUSD");
        assertEq(IERC20(WMON).balanceOf(address(adapter)), 0, "adapter kept WMON");
    }

    /// @dev The callback is gated: a stranger calling it outside a swap (slot zero) must revert.
    function test_callback_gate_rejects_stranger() public {
        vm.expectRevert(bytes("V3_BAD_CALLBACK"));
        adapter.uniswapV3SwapCallback(int256(1), int256(-1), abi.encode(WMON));
    }
}
