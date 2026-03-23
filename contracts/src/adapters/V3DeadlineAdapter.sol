// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

interface ISwapRouterDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title V3DeadlineAdapter
/// @notice Executes swaps on V3 forks that use the deadline-style SwapRouter
/// @dev Used for Capricorn, PancakeSwap V3, and other V3 forks with deadline param
contract V3DeadlineAdapter is IAdapter {
    ISwapRouterDeadline public immutable ROUTER;

    constructor(address router_) {
        ROUTER = ISwapRouterDeadline(router_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(uint24 fee)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        uint24 fee = abi.decode(extraData, (uint24));

        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);

        amountOut = ROUTER.exactInputSingle(
            ISwapRouterDeadline.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: to,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);
    }
}
