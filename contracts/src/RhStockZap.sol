// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

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
/// runs a two-step `txs[]` on the destination: `[USDG.approve(this, MAX), this.zapFrom(...)]`.
/// This proxy then reads the executor's LIVE USDG balance and swaps ALL of it into the target stock,
/// sending the stock straight to the buyer.
///
/// Why a proxy at all — the amount that survives the bridge is not known when the quote is built, so
/// hardcoding `amountIn` into an `exactInputSingle` calldata mismatches what actually arrives and the
/// swap reverts with TRANSFER_FROM_FAILED (observed live in Phase 0). Relay's own Call Integration
/// Guide prescribes exactly this: route through your own proxy, approve it for MAX, and have it pull
/// the caller's full balance and read the live amount at execution time.
///
/// Safety properties:
///   * Front-run immune — funds are PULLED from `msg.sender` (the Relay executor that holds the
///     bridged USDG and granted the approval in the same atomic fill). An arbitrary external caller
///     has `balanceOf(msg.sender) == 0`, so `zapFrom` reverts for them and nothing can be siphoned.
///   * Never strands funds — if the swap reverts (thin pool, wrong tier, minOut too tight) the pulled
///     USDG is forwarded to the buyer, who can finish via the existing gasless flow. The contract
///     holds a zero balance between calls, so a leftover can never be swept by a later buyer.
///   * No owner, no upgrade, no privileged keys — it only ever moves the USDG it pulled in this call.
contract RhStockZap {
    IERC20 public immutable USDG;
    ISwapRouter02 public immutable ROUTER;

    event Zapped(address indexed buyer, address indexed stock, uint24 fee, uint256 usdgIn, uint256 stockOut);
    event ZapReturned(address indexed buyer, uint256 usdgReturned);

    error NoBalance();
    error PullFailed();

    constructor(address usdg, address router) {
        USDG = IERC20(usdg);
        ROUTER = ISwapRouter02(router);
    }

    /// @notice Swap the caller's full USDG balance into `stock` and send it to `buyer`.
    /// @param stock  destination stock token (USDG/stock Uniswap V3 pool must exist at `fee`)
    /// @param fee    the USDG/stock V3 pool fee tier — resolved off-chain to the deepest pool
    /// @param buyer  final recipient of the stock (or of the USDG if the swap reverts)
    /// @param minOut slippage floor in stock units; the buyer already accepted the quote off-chain
    function zapFrom(address stock, uint24 fee, address buyer, uint256 minOut) external {
        uint256 bal = USDG.balanceOf(msg.sender);
        if (bal == 0) revert NoBalance();
        if (!USDG.transferFrom(msg.sender, address(this), bal)) revert PullFailed();

        USDG.approve(address(ROUTER), bal);
        try
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(USDG),
                    tokenOut: stock,
                    fee: fee,
                    recipient: buyer,
                    amountIn: bal,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            )
        returns (uint256 out) {
            emit Zapped(buyer, stock, fee, bal, out);
        } catch {
            // Swap failed — hand the buyer their USDG so the gasless flow can finish the trade.
            USDG.approve(address(ROUTER), 0);
            USDG.transfer(buyer, bal);
            emit ZapReturned(buyer, bal);
        }
    }
}
