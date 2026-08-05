// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface INadFunDexRouter {
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

    function buy(BuyParams calldata params) external payable returns (uint256 amountOut);
    function sell(SellParams calldata params) external returns (uint256 amountOut);
}

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title NadFunDEXAdapter
/// @notice Executes swaps on Nad.fun DEX (POST-graduation tokens)
/// @dev DEXRouter: 0x0B79d71AE99528D1dB24A4148b5f4F865cc2b137
///      Same buy/sell interface as BondingCurveRouter but with return values.
///      Only works for graduated tokens (lens.isGraduated(token) == true).
///
///      H1/M9 (2026-08-05 audit): destination is the IMMUTABLE DEXRouter (no caller-named address is
///      ever paid), but swap() was world-callable and `token` was unbound to the route — the same
///      "measure one token, pay out another" primitive as the BC adapter. Fixed by `onlyRouter` +
///      the route binding below, plus native-residual reconciliation.
contract NadFunDEXAdapter is IAdapter, BaseAdapter {
    INadFunDexRouter public immutable DEX_ROUTER;
    address public immutable WMON;

    /// @notice extraData's `token`/`isBuy` do not match the route the router is pricing.
    error TokenNotBoundToRoute();

    constructor(address nullRouter_, address dexRouter_, address wmon_) BaseAdapter(nullRouter_) {
        require(dexRouter_ != address(0) && wmon_ != address(0), "NADDEX_ZERO_ADDR");
        DEX_ROUTER = INadFunDexRouter(dexRouter_);
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address token, bool isBuy)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address token, bool isBuy) = abi.decode(extraData, (address, bool));
        // M9: buy → WMON in / `token` out; sell → `token` in / WMON out. Nothing tied these before.
        bool bound = isBuy
            ? (token == tokenOut && tokenIn == WMON)
            : (token == tokenIn && tokenOut == WMON);
        if (!bound) revert TokenNotBoundToRoute();

        if (isBuy) {
            IWMON(WMON).withdraw(amountIn);
            amountOut = DEX_ROUTER.buy{value: amountIn}(
                INadFunDexRouter.BuyParams({
                    amountOutMin: 1,
                    token: token,
                    to: to,
                    deadline: block.timestamp + 300
                })
            );
            // M9: any native refund from the venue would otherwise be stranded forever on this
            // immutable, ownerless adapter (it has receive() but never reconciled).
            _forwardResidualNative(to);
        } else {
            TransferLib.safeApprove(tokenIn, address(DEX_ROUTER), amountIn);
            uint256 monBefore = address(this).balance;
            amountOut = DEX_ROUTER.sell(
                INadFunDexRouter.SellParams({
                    amountIn: amountIn,
                    amountOutMin: 1,
                    token: token,
                    to: address(this),
                    deadline: block.timestamp + 300
                })
            );
            // sell sends native MON to address(this)
            uint256 monReceived = address(this).balance - monBefore;
            amountOut = monReceived;
            TransferLib.safeApprove(tokenIn, address(DEX_ROUTER), 0);
            // Wrap+forward the ENTIRE native balance (proceeds AND any residual) while reporting only
            // this swap's proceeds — under-reporting is safe (extra WMON at NullRouter is dust-swept
            // back to the user); over-reporting is the M1 hazard.
            _forwardResidualNative(to);
        }
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
