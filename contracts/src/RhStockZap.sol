// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title RhStockZap
/// @notice One-shot destination-execution proxy for cross-chain stock buys on Robinhood Chain.
///
/// A Monad user pays MON (or USDC), Relay bridges it to USDG on 4663, and the Relay call-executor
/// runs a two-step `txs[]` on the destination: `[USDG.approve(this, maxIn), this.zapFrom(...)]`.
/// This proxy then reads the executor's LIVE USDG balance and swaps `min(balance, maxIn)` into the
/// target stock, sending the stock straight to the buyer.
///
/// Why a proxy at all — the amount that survives the bridge is not known when the quote is built, so
/// hardcoding `amountIn` into an `exactInputSingle` calldata mismatches what actually arrives and the
/// swap reverts with TRANSFER_FROM_FAILED (observed live in Phase 0). Relay's own Call Integration
/// Guide prescribes exactly this: route through your own proxy and read the live amount at execution
/// time. What it does NOT require is an unbounded pull — hence `maxIn`.
///
/// Safety properties:
///   * Bounded pull — takes `min(balanceOf(msg.sender), maxIn)`, never the caller's entire balance.
///     Audit 2026-08-05 H5: the previous version swept the executor's WHOLE balance to a caller-chosen
///     `buyer`, so correctness rested on an invariant this contract cannot check — that the shared Relay
///     executor never holds another user's USDG at that instant. An attacker submitting their own order
///     with `buyer = ATTACKER` and a bogus fee tier would fall into the `catch` and walk away with the
///     victim's bridged funds. `maxIn` = the caller's own `sizeBridged`, which it already computes.
///     (Verified dormant when this was written — 0 balance, 0 events in 400k blocks, 0 standing
///     approvals — so this is fix-before-first-use, not incident response.)
///   * Front-run immune — funds are PULLED from `msg.sender` (the Relay executor that holds the
///     bridged USDG and granted the approval in the same atomic fill). An arbitrary external caller
///     has `balanceOf(msg.sender) == 0`, so `zapFrom` reverts for them and nothing can be siphoned.
///   * Never strands funds — if the swap reverts (thin pool, wrong tier, minOut too tight) the pulled
///     USDG is forwarded to the buyer, who can finish via the existing gasless flow. The contract
///     holds a zero balance between calls, so a leftover can never be swept by a later buyer. That
///     refund uses SafeERC20 (L8): the raw `transfer` it replaced discarded its return value in a
///     contract with no rescue, no owner and no upgrade path, so a `false` return would have stranded
///     the user's full bridged amount forever while emitting `ZapReturned` claiming success.
///   * No owner, no upgrade, no privileged keys — it only ever moves the USDG it pulled in this call.
contract RhStockZap {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDG;
    ISwapRouter02 public immutable ROUTER;

    event Zapped(address indexed buyer, address indexed stock, uint24 fee, uint256 usdgIn, uint256 stockOut);
    event ZapReturned(address indexed buyer, uint256 usdgReturned);

    error NoBalance();
    error BadBuyer();
    error BadMaxIn();

    constructor(address usdg, address router) {
        USDG = IERC20(usdg);
        ROUTER = ISwapRouter02(router);
    }

    /// @notice Swap up to `maxIn` of the caller's USDG into `stock` and send it to `buyer`.
    /// @param stock  destination stock token (USDG/stock Uniswap V3 pool must exist at `fee`)
    /// @param fee    the USDG/stock V3 pool fee tier — resolved off-chain to the deepest pool
    /// @param buyer  final recipient of the stock (or of the USDG if the swap reverts)
    /// @param minOut slippage floor in stock units; the buyer already accepted the quote off-chain
    /// @param maxIn  hard ceiling on what this call may pull — the caller's own bridged size. The
    ///               actual pull is `min(balance, maxIn)` because bridge fees make the arriving amount
    ///               unknowable at quote time, so it may be slightly SHORT of maxIn but never over.
    function zapFrom(address stock, uint24 fee, address buyer, uint256 minOut, uint256 maxIn) external {
        // L8: SwapRouter02 conventionally remaps a zero recipient to itself, where a permissionless
        // `sweepToken` exists — a zero buyer would donate the trade to whoever sweeps first.
        if (buyer == address(0)) revert BadBuyer();
        if (maxIn == 0) revert BadMaxIn();

        uint256 bal = USDG.balanceOf(msg.sender);
        uint256 amount = bal < maxIn ? bal : maxIn;
        if (amount == 0) revert NoBalance();
        USDG.safeTransferFrom(msg.sender, address(this), amount);

        USDG.forceApprove(address(ROUTER), amount);
        try
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(USDG),
                    tokenOut: stock,
                    fee: fee,
                    recipient: buyer,
                    amountIn: amount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            )
        returns (uint256 out) {
            emit Zapped(buyer, stock, fee, amount, out);
        } catch {
            // Swap failed — hand the buyer their USDG so the gasless flow can finish the trade.
            USDG.forceApprove(address(ROUTER), 0);
            USDG.safeTransfer(buyer, amount);
            emit ZapReturned(buyer, amount);
        }
    }
}
