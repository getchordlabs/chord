// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

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

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title PancakeV3Adapter
/// @notice Executes swaps on PancakeSwap V3 / Uniswap V3 via SwapRouter02 on Monad
/// @dev Simple ERC20-to-ERC20 swaps. No native MON handling needed — Router wraps/unwraps.
///
/// SwapRouter02: 0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900
/// Factory:      0x204faca1764b154221e35c0d20abb3c525710498
/// QuoterV2:     0x661e93cca42afacb172121ef892830ca3b70f08d
///
/// Pools verified (WMON/USDC):
///   fee=500:   0x5Bc39A29EA5d8315263EC8939d6AD393dEbC34E9
///   fee=3000:  0x659bD0BC4167BA25c62E05656F78043E7eD4a9da
///   fee=10000: 0xC33e9E441e6f4E74CdB34f878bE51189C9CB00D8
contract PancakeV3Adapter is IAdapter {
    ISwapRouter02 public immutable ROUTER;

    constructor(address router_) {
        ROUTER = ISwapRouter02(router_);
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

        // Approve router
        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);

        // Execute swap — tokens go directly to recipient
        amountOut = ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: to,
                amountIn: amountIn,
                amountOutMinimum: 0, // Router handles slippage
                sqrtPriceLimitX96: 0
            })
        );

        // Reset approval
        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);
    }
}
