// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface INadFunRouter {
    struct BuyParams {
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    struct SellParams {
        uint256 amountIn;
        uint256 amountOutMin;
        address token;
        address to;
        uint256 deadline;
    }

    function buy(BuyParams calldata params) external payable;
    function sell(SellParams calldata params) external;
}

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title NadFunBCAdapter
/// @notice Executes swaps on Nad.fun Bonding Curve (PRE-graduation tokens)
/// @dev BondingCurveRouter: 0x6F6B8F1a20703309951a5127c45B49b1CD981A22
///      buy() = send native MON, receive token
///      sell() = send token, receive native MON
///      Check lens.isGraduated(token) before routing — only works for non-graduated tokens
///
///      H1/M9 (2026-08-05 audit): the destination is the IMMUTABLE BondingCurveRouter, so no
///      caller-named address ever receives funds — but swap() was world-callable (`onlyRouter` now)
///      and `token` came from extraData COMPLETELY UNBOUND to the route: `:73` returned a balanceOf
///      delta OF `token` that the router then consumes as an amount of `route.tokenOut`, reaching
///      M1's over-reporting primitive with no fake pool at all. The route binding below is the
///      provenance for this venue.
contract NadFunBCAdapter is IAdapter, BaseAdapter {
    INadFunRouter public immutable BC_ROUTER;
    address public immutable WMON;

    /// @notice extraData's `token`/`isBuy` do not match the route the router is pricing.
    error TokenNotBoundToRoute();

    constructor(address nullRouter_, address bcRouter_, address wmon_) BaseAdapter(nullRouter_) {
        require(bcRouter_ != address(0) && wmon_ != address(0), "NADBC_ZERO_ADDR");
        BC_ROUTER = INadFunRouter(bcRouter_);
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address token, bool isBuy)
    ///      isBuy=true: WMON→token (unwrap WMON, send MON via buy())
    ///      isBuy=false: token→WMON (sell token, receive MON, wrap to WMON)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address token, bool isBuy) = abi.decode(extraData, (address, bool));
        // M9: bind the curve token to the route. Without this the adapter measures one token and the
        // router pays out another, and nothing forced tokenIn == WMON before unwrapping.
        _requireBoundToRoute(token, isBuy, tokenIn, tokenOut);

        if (isBuy) {
            // WMON → token: unwrap WMON, send native MON
            IWMON(WMON).withdraw(amountIn);
            uint256 balBefore = IERC20(token).balanceOf(to);
            BC_ROUTER.buy{value: amountIn}(
                INadFunRouter.BuyParams({
                    amountOutMin: 1,
                    token: token,
                    to: to,
                    deadline: block.timestamp + 300
                })
            );
            amountOut = IERC20(token).balanceOf(to) - balBefore;
            // M9: a bonding-curve refund at the graduation boundary lands here as native MON. This
            // contract has receive() but never reconciled its native balance, so any refund was
            // unreachable FOREVER (immutable, ownerless, no rescue). Re-wrap and forward it.
            _forwardResidualNative(to);
        } else {
            // token → WMON: sell token, receive native MON, wrap
            TransferLib.safeApprove(tokenIn, address(BC_ROUTER), amountIn);
            uint256 monBefore = address(this).balance;
            BC_ROUTER.sell(
                INadFunRouter.SellParams({
                    amountIn: amountIn,
                    amountOutMin: 1,
                    token: token,
                    to: address(this),
                    deadline: block.timestamp + 300
                })
            );
            amountOut = address(this).balance - monBefore;
            TransferLib.safeApprove(tokenIn, address(BC_ROUTER), 0);
            // Wrap+forward the ENTIRE native balance (proceeds AND any pre-existing residual), while
            // reporting only this swap's proceeds — over-reporting is what M1 punishes, extra WMON
            // reaching NullRouter is simply dust-swept back to the user.
            _forwardResidualNative(to);
        }
    }

    /// @dev M9 route binding. buy: WMON in, `token` out. sell: `token` in, WMON out.
    function _requireBoundToRoute(address token, bool isBuy, address tokenIn, address tokenOut)
        internal
        view
    {
        bool ok = isBuy
            ? (token == tokenOut && tokenIn == WMON)
            : (token == tokenIn && tokenOut == WMON);
        if (!ok) revert TokenNotBoundToRoute();
    }

    /// @dev M9: never leave native MON on this immutable, ownerless adapter — wrap and forward it.
    function _forwardResidualNative(address to) internal {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            IWMON(WMON).deposit{value: bal}();
            TransferLib.safeTransfer(WMON, to, bal);
        }
    }

    receive() external payable {}
}
