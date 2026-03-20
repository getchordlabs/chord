// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurvePool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

/// @title CurveAdapter
/// @notice Executes swaps on Curve pools via exchange()
/// @dev Works with StableSwap and TwoCrypto pools.
///      StableSwap Factory: 0x8271e06E5887FE5ba05234f5315c19f3Ec90E8aD
///      TwoCrypto Factory: 0xe7FBd704B938cB8fe26313C3464D4b7B7348c88C
contract CurveAdapter is IAdapter {

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool, uint256 i, uint256 j)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        (address pool, uint256 i, uint256 j) =
            abi.decode(extraData, (address, uint256, uint256));

        // Approve pool
        TransferLib.safeApprove(tokenIn, pool, amountIn);

        // Record output balance
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap
        ICurvePool(pool).exchange(i, j, amountIn, 0);

        // Calculate output
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        // Transfer to recipient
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Reset approval
        TransferLib.safeApprove(tokenIn, pool, 0);
    }
}
