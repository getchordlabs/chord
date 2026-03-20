// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
contract NadFunBCAdapter is IAdapter {
    INadFunRouter public immutable BC_ROUTER;
    address public immutable WMON;

    constructor(address bcRouter_, address wmon_) {
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
    ) external override returns (uint256 amountOut) {
        (address token, bool isBuy) = abi.decode(extraData, (address, bool));

        if (isBuy) {
            // WMON → token: unwrap WMON, send native MON
            IWMON(WMON).withdraw(amountIn);
            uint256 balBefore = IERC20(token).balanceOf(to);
            BC_ROUTER.buy{value: amountIn}(
                INadFunRouter.BuyParams({
                    amountOutMin: 0,
                    token: token,
                    to: to,
                    deadline: block.timestamp + 300
                })
            );
            amountOut = IERC20(token).balanceOf(to) - balBefore;
        } else {
            // token → WMON: sell token, receive native MON, wrap
            TransferLib.safeApprove(tokenIn, address(BC_ROUTER), amountIn);
            uint256 monBefore = address(this).balance;
            BC_ROUTER.sell(
                INadFunRouter.SellParams({
                    amountIn: amountIn,
                    amountOutMin: 0,
                    token: token,
                    to: address(this),
                    deadline: block.timestamp + 300
                })
            );
            amountOut = address(this).balance - monBefore;
            IWMON(WMON).deposit{value: amountOut}();
            TransferLib.safeTransfer(WMON, to, amountOut);
            TransferLib.safeApprove(tokenIn, address(BC_ROUTER), 0);
        }
    }

    receive() external payable {}
}
