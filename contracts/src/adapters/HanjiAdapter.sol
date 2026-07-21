// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Hanji on-chain CLOB — one FastQuoterProxy per market (e.g. MON/USDC
///         0x1aed222dda944a87703c918745b11be13f8eef10). Orders execute on the PROXY and ERC20
///         approvals target the PROXY. The proxy is UUPS and can rotate generations, so nothing
///         market-specific is pinned here — the proxy arrives per-swap via extraData and ALL
///         market config (scaling factors, token pair) is read on-chain via getConfig() at swap
///         time. Selectors verified live 2026-07-22: getConfig 0xc3f909d4, placeOrder 0xf513ef4c,
///         placeMarketOrderWithTargetValue 0xad73d32e.
interface IHanjiProxy {
    /// @notice Full market config. quantity units: base SHARES = rawWei / scalingFactorTokenX;
    ///         quote value units: rawWei / scalingFactorTokenY.
    function getConfig()
        external
        view
        returns (
            uint256 scalingFactorTokenX,
            uint256 scalingFactorTokenY,
            address tokenX,
            address tokenY,
            bool supportsNativeEth,
            bool isTokenXWeth,
            address askTrie,
            address bidTrie,
            uint64 adminCommissionRate,
            uint64 totalAggressiveCommissionRate,
            uint64 totalPassiveCommissionRate,
            uint64 passiveOrderPayoutRate,
            bool shouldInvokeOnTrade
        );

    /// @notice IOC when marketOnly=true: no-fill returns (0,0,0,0) WITHOUT reverting and refunds
    ///         the input; a partial fill refunds the unfilled remainder. Refunds/proceeds on the
    ///         native-capable side arrive as a PLAIN NATIVE value-send to msg.sender.
    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72 price,
        uint128 maxCommission,
        bool marketOnly,
        bool postOnly,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint64 orderId, uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);

    /// @notice Market BUY of base spending EXACTLY targetTokenYValue of quote (taker fee is taken
    ///         FROM that amount). ERC20 input is pulled via transferFrom from msg.sender.
    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72 price,
        uint128 maxCommission,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);
}

interface IWMON {
    function deposit() external payable;
}

/// @title HanjiAdapter
/// @notice Executes IOC taker swaps on the Hanji CLOB via a per-market FastQuoterProxy.
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn here BEFORE calling swap();
///      this adapter never transferFrom's the caller. Output is measured by balance delta and
///      forwarded to `to`; the adapter ends every swap with ZERO balance of tokenIn, tokenOut and
///      native.
///
///      extraData = abi.encode(address proxy) ONLY. Everything else (scaling factors, tokenX/Y) is
///      read from the proxy's getConfig() at swap time — encoding market config off-chain would
///      recreate the stale-extraData bug class (config rotates with proxy generations; the on-chain
///      read can never be stale).
///
///      Direction is derived from the pair: tokenIn==tokenX → SELL base via placeOrder(isAsk=true,
///      marketOnly=true) with quantity in SHARES (rawWei / scalingFactorTokenX, floored);
///      tokenIn==tokenY → BUY base via placeMarketOrderWithTargetValue(isAsk=false) spending
///      exactly amountIn/scalingFactorTokenY of quote (taker fee inside the input). Price bounds
///      are no-op sentinels (1 for sells, 999999e15 for buys — Long Gamma's own router does the
///      same); NullRouter's global minOut is the real slippage protection, so no minOut/deadline
///      logic lives here. `expires` is block.timestamp + 300 (venue reverts past-expiry orders).
///
///      Native handling: the router never sends native here (it wraps MON→WMON first, tokenIn is
///      always ERC20 — WMON works on the native-capable side without msg.value). But the venue
///      pays native-side PROCEEDS AND REFUNDS as plain value-sends to msg.sender, so this contract
///      has `receive()` and re-wraps its entire native balance to WMON after the venue call, BEFORE
///      measuring the output delta.
///
///      Leftover input (sub-share flooring dust + IOC partial-fill refunds, already re-wrapped if
///      they arrived native) is forwarded to `to` after the output — on single-hop `to` is
///      NullRouter, whose dust-sweep returns it to the user. A full IOC no-fill (venue refunds
///      everything without reverting) leaves the output delta at zero → revert HANJI_NO_FILL so
///      the router never treats a refund as a fill.
contract HanjiAdapter is IAdapter {
    /// @notice Canonical WMON — native proceeds/refunds are re-wrapped here before forwarding.
    address public immutable WMON;

    /// @notice No-op worst-price bound for sells (venue treats it as "any price").
    uint72 private constant SELL_PRICE_NO_BOUND = 1;
    /// @notice No-op worst-price bound for buys (uint72-safe, ≤6 significant digits as required).
    uint72 private constant BUY_PRICE_NO_BOUND = 999999e15;
    /// @notice IOC order lifetime — venue reverts when block.timestamp > expires.
    uint256 private constant EXPIRY_WINDOW = 300;

    constructor(address wmon_) {
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address proxy) — the market's FastQuoterProxy.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address proxy = abi.decode(extraData, (address));

        (uint256 sfX, uint256 sfY, address tokenX, address tokenY,,,,,,,,,) = IHanjiProxy(proxy).getConfig();

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        if (tokenIn == tokenX && tokenOut == tokenY) {
            // SELL base: IOC ask, quantity in shares (floored — sub-share dust refunded below).
            uint256 shares = amountIn / sfX;
            require(shares > 0, "HANJI_DUST");
            require(shares <= type(uint128).max, "HANJI_OVERFLOW");
            uint256 used = shares * sfX;

            TransferLib.safeApprove(tokenIn, proxy, used);
            IHanjiProxy(proxy).placeOrder(
                true, // isAsk — sell base
                uint128(shares),
                SELL_PRICE_NO_BOUND,
                type(uint128).max, // maxCommission — price bound + router minOut protect
                true, // marketOnly — IOC, no resting order
                false, // postOnly
                true, // transferExecutedTokens — pay out in the same tx
                block.timestamp + EXPIRY_WINDOW
            );
            TransferLib.safeApprove(tokenIn, proxy, 0);
        } else if (tokenIn == tokenY && tokenOut == tokenX) {
            // BUY base: spend exactly `target` of quote (taker fee taken from inside that amount).
            uint256 target = amountIn / sfY;
            require(target > 0, "HANJI_DUST");
            require(target <= type(uint128).max, "HANJI_OVERFLOW");
            uint256 used = target * sfY;

            TransferLib.safeApprove(tokenIn, proxy, used);
            IHanjiProxy(proxy).placeMarketOrderWithTargetValue(
                false, // isAsk=false — buy base
                uint128(target),
                BUY_PRICE_NO_BOUND,
                type(uint128).max, // maxCommission — price bound + router minOut protect
                true, // transferExecutedTokens — pay out in the same tx
                block.timestamp + EXPIRY_WINDOW
            );
            TransferLib.safeApprove(tokenIn, proxy, 0);
        } else {
            revert("HANJI_PAIR_MISMATCH");
        }

        // Native-side proceeds/refunds arrived as plain value-sends — re-wrap ALL of it to WMON
        // before measuring anything, so both the output delta and the leftover sweep see ERC20.
        if (address(this).balance > 0) {
            IWMON(WMON).deposit{ value: address(this).balance }();
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut > 0, "HANJI_NO_FILL");
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Sub-share flooring dust + IOC partial-fill refunds → back to `to` (router dust-sweep
        // returns it to the user on single-hop). Adapter MUST end at zero balance of everything.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @notice Accepts the venue's native value-sends (proceeds and IOC refunds on the
    ///         native-capable side).
    receive() external payable { }
}
