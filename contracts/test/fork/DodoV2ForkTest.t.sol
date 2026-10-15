// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordDodoV2Adapter} from "../../src/chord/ChordDodoV2Adapter.sol";

interface IDodoQuery {
    function querySellBase(address trader, uint256 payBaseAmount) external view returns (uint256, uint256, uint8, uint256);
    function querySellQuote(address trader, uint256 payQuoteAmount) external view returns (uint256, uint256, uint8, uint256);
    function _BASE_TOKEN_() external view returns (address);
    function _QUOTE_TOKEN_() external view returns (address);
}

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Mainnet fork: the Chord DODO V2 adapter against the market-maker DPP pools KyberSwap routes (`dodo-dpp`). Each leg
///         must deliver the pool's own `querySell*` for tx.origin at the same block — the number the engine quotes.
///         Run: forge test --match-contract DodoV2ForkTest --fork-url <chain rpc> -vv (the other chain's test skips itself).
contract DodoV2ForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant USER = address(0xB0B);

    function _run(address factory, address pool, uint256 baseIn) internal {
        address[] memory fs = new address[](1);
        fs[0] = factory;
        ChordDodoV2Adapter a = new ChordDodoV2Adapter(ROUTER, fs);
        address base = IDodoQuery(pool)._BASE_TOKEN_();
        address quote = IDodoQuery(pool)._QUOTE_TOKEN_();
        // sell base
        (uint256 q,,,) = IDodoQuery(pool).querySellBase(tx.origin, baseIn);
        deal(base, address(a), baseIn);
        vm.prank(ROUTER);
        uint256 got = a.swap(base, quote, baseIn, USER, abi.encode(pool));
        assertEq(got, q, "sell base != querySellBase");
        assertEq(IERC20D(quote).balanceOf(USER), got);
        // sell the quote back
        vm.prank(USER);
        IERC20D(quote).transfer(address(a), got);
        (uint256 q2,,,) = IDodoQuery(pool).querySellQuote(tx.origin, got);
        vm.prank(ROUTER);
        uint256 back = a.swap(quote, base, got, USER, abi.encode(pool));
        assertEq(back, q2, "sell quote != querySellQuote");
        console2.log("base in", baseIn, "quote out", got);
        console2.log("base back", back, "kept bps", back * 10_000 / baseIn);
        assertGe(back * 10_000 / baseIn, 9_980, "round trip kept too little");
        assertEq(IERC20D(base).balanceOf(address(a)) + IERC20D(quote).balanceOf(address(a)), 0, "adapter holds nothing");
    }

    /// Avalanche — DPP Advanced WETH.e/USDC 0xb300709b… (90 WETH.e + 245,640 USDC on 2026-10-14), DPPFactory 0xb7865a5c….
    function test_avalanche_weth_usdc() public {
        if (block.chainid != 43114) return;
        _run(0xb7865a5ceE051d35B09A48b624D7057d3362655a, 0xb300709BC56856560CC4Cf521d29AC2cd941E041, 2e18);
    }

    /// Arbitrum — DPP Advanced WETH/USDC 0x1666ea6e… (113 WETH + 359,834 USDC on 2026-10-14), DPPFactory 0xa6Cf3d16….
    function test_arbitrum_weth_usdc() public {
        if (block.chainid != 42161) return;
        _run(0xa6Cf3d163358aF376ec5e8B7Cc5e102a05FdE63D, 0x1666EA6E83BCC3473111732Ef086BA47e6EDDeB7, 2e18);
    }
}
