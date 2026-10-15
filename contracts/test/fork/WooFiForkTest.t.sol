// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordWooFiAdapter} from "../../src/chord/ChordWooFiAdapter.sol";
import {IWooPPV2} from "../../src/adapters/WooFiAdapter.sol";

interface IERC20W {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Mainnet fork: the Chord WOOFi adapter against WOOFi's real WooPPV2 (same address on every chain). Each test
///         sells the quote token for a base token, sells the proceeds back, then base → base, and every fill must equal
///         WooPPV2's own `query` at the same state — the number the engine quotes.
///         Run one chain: WOOFI_FORK_RPC=<url> forge test --match-contract WooFiForkTest --fork-url <url> -vv
///         (a test for another chain skips itself). Excluded from CI with the other *ForkTest suites.
contract WooFiForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a; // Chord router proxy, every chain
    address constant POOL = 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4;
    address constant USER = address(0xB0B);

    ChordWooFiAdapter adapter;

    function setUp() public {
        adapter = new ChordWooFiAdapter(ROUTER, POOL);
    }

    function _swap(address tin, address tout, uint256 amt) internal returns (uint256 out) {
        uint256 q = IWooPPV2(POOL).query(tin, tout, amt);
        uint256 before = IERC20W(tout).balanceOf(USER);
        vm.prank(ROUTER);
        out = adapter.swap(tin, tout, amt, USER, abi.encode(POOL));
        assertEq(IERC20W(tout).balanceOf(USER) - before, out, "delivered != returned");
        assertEq(out, q, "execution != WooPPV2.query");
        assertEq(IERC20W(tin).balanceOf(address(adapter)), 0, "input left in the adapter");
        assertEq(IERC20W(tout).balanceOf(address(adapter)), 0, "output left in the adapter");
    }

    /// quote → base → quote, then a base → base hop; keepBps bounds the round trip (two fees + two spreads).
    function _run(address quote, address base, address base2, uint256 amtQuote, uint256 keepBps) internal {
        assertEq(IWooPPV2(POOL).quoteToken(), quote, "quote token");
        deal(quote, address(adapter), amtQuote);
        uint256 got = _swap(quote, base, amtQuote);
        console2.log("quote -> base", amtQuote, got);

        vm.prank(USER);
        IERC20W(base).transfer(address(adapter), got);
        uint256 back = _swap(base, quote, got);
        console2.log("base -> quote", got, back);
        assertGt(back, amtQuote * keepBps / 10_000, "round trip kept too little");

        if (base2 != address(0)) {
            deal(base, address(adapter), got / 2);
            uint256 b2 = _swap(base, base2, got / 2);
            console2.log("base -> base2", got / 2, b2);
            assertGt(b2, 0);
        }
    }

    /// Monad 143 — quote USDC; WMON 216k, WETH 9.9, WBTC 0.2 in the pool on 2026-10-14.
    function test_monad_usdc_weth_wmon() public {
        if (block.chainid != 143) return;
        _run(
            0x754704Bc059F8C67012fEd69BC8A327a5aafb603, // USDC
            0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242, // WETH
            0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A, // WMON
            2_000e6,
            9_950
        );
    }

    /// Avalanche 43114 — quote USDC; WAVAX 14.9k + 182k USDC in the pool on 2026-10-14.
    function test_avalanche_usdc_wavax_btcb() public {
        if (block.chainid != 43114) return;
        _run(
            0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, // USDC
            0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, // WAVAX
            0x152b9d0FdC40C096757F570A51E494bd4b943E50, // BTC.b
            5_000e6,
            9_950
        );
    }

    /// Base 8453 — quote USDC; WETH 60 + 99.5k USDC on 2026-10-14.
    function test_base_usdc_weth() public {
        if (block.chainid != 8453) return;
        _run(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x4200000000000000000000000000000000000006, address(0), 5_000e6, 9_950);
    }

    /// BNB 56 — quote USDT (18 decimals); WBNB 147 + 250k USDT on 2026-10-14.
    function test_bnb_usdt_wbnb() public {
        if (block.chainid != 56) return;
        _run(0x55d398326f99059fF775485246999027B3197955, 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, address(0), 5_000e18, 9_950);
    }
}
