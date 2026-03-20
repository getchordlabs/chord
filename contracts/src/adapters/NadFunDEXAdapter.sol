// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
contract NadFunDEXAdapter is IAdapter {
    INadFunDexRouter public immutable DEX_ROUTER;
    address public immutable WMON;

    constructor(address dexRouter_, address wmon_) {
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
    ) external override returns (uint256 amountOut) {
        (address token, bool isBuy) = abi.decode(extraData, (address, bool));

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
            IWMON(WMON).deposit{value: monReceived}();
            TransferLib.safeTransfer(WMON, to, monReceived);
            amountOut = monReceived;
            TransferLib.safeApprove(tokenIn, address(DEX_ROUTER), 0);
        }
    }

    receive() external payable {}
}
