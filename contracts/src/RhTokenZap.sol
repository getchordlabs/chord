// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RhTokenZap
 * @notice Destination-execution proxy for Swap V2 on Robinhood Chain: the bridge solver delivers the
 *         anchor (USDG) and calls `zapFrom`, which routes it into ANY token through the pinned
 *         NullRouter and hands the output to the buyer — one signature on the origin chain, no gas on
 *         Robinhood. Generalises RhStockZap (Uniswap V3 single pool, stocks only) to the whole engine
 *         route set: the API builds the router calldata for THIS contract as the caller.
 *
 * @dev Same trust shape as RhStockZap: no owner, no custody between calls, nothing upgradeable. The
 *      caller (the solver) is only ever able to spend the caller's own USDG balance, capped by `maxIn`,
 *      and only into the buyer's address: the router delivers to msg.sender = this contract, and this
 *      contract forwards the ENTIRE tokenOut delta to `buyer`. If the route fails or under-delivers
 *      (`minOut`), the USDG goes to the buyer instead of reverting — a revert inside a Relay fill would
 *      strand the anchor with the solver, which is the one outcome the buyer cannot recover from.
 */
contract RhTokenZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable ANCHOR; // USDG on 4663
    address public immutable ROUTER; // NullRouter on 4663

    event Zapped(address indexed buyer, address indexed tokenOut, uint256 anchorIn, uint256 out);
    event ZapReturned(address indexed buyer, uint256 anchorReturned, bytes reason);

    error NoBalance();
    error BadBuyer();
    error BadMaxIn();
    error BadToken();

    constructor(address anchor, address router) {
        ANCHOR = IERC20(anchor);
        ROUTER = router;
    }

    /**
     * @param tokenOut       Token the buyer wants (never the anchor itself).
     * @param buyer          Who receives `tokenOut`, or the anchor back on failure.
     * @param minOut         Floor on `tokenOut` delivered; below it the anchor is returned instead.
     * @param maxIn          Cap on the anchor spent — the API sets it to the sized bridge amount + headroom,
     *                       so a solver over-delivery cannot be swept into a bad route.
     * @param routerCalldata Router call built by the API for this contract as msg.sender, sized to the
     *                       amount the API expected; `amountIn` inside it must be ≤ the anchor pulled here.
     */
    function zapFrom(address tokenOut, address buyer, uint256 minOut, uint256 maxIn, bytes calldata routerCalldata)
        external
        nonReentrant
    {
        if (buyer == address(0)) revert BadBuyer();
        if (maxIn == 0) revert BadMaxIn();
        if (tokenOut == address(ANCHOR) || tokenOut == address(0)) revert BadToken();

        uint256 bal = ANCHOR.balanceOf(msg.sender);
        uint256 amount = bal < maxIn ? bal : maxIn;
        if (amount == 0) revert NoBalance();
        ANCHOR.safeTransferFrom(msg.sender, address(this), amount);
        ANCHOR.forceApprove(ROUTER, amount);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        (bool ok, bytes memory reason) = ROUTER.call(routerCalldata);
        uint256 out = ok ? IERC20(tokenOut).balanceOf(address(this)) - outBefore : 0;
        ANCHOR.forceApprove(ROUTER, 0);

        if (ok && out >= minOut && out > 0) {
            IERC20(tokenOut).safeTransfer(buyer, out);
            // Any anchor the route did not consume (router used less than pulled) goes back too.
            uint256 left = ANCHOR.balanceOf(address(this));
            if (left > 0) ANCHOR.safeTransfer(buyer, left);
            emit Zapped(buyer, tokenOut, amount - left, out);
        } else {
            // Route failed or under-delivered: hand back everything, including any partial output.
            if (out > 0) IERC20(tokenOut).safeTransfer(buyer, out);
            uint256 left = ANCHOR.balanceOf(address(this));
            if (left > 0) ANCHOR.safeTransfer(buyer, left);
            emit ZapReturned(buyer, left, ok ? bytes("InsufficientOutput") : reason);
        }
    }
}
