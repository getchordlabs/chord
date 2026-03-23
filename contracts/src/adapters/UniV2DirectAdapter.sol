// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

interface IUniV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title UniV2DirectAdapter
/// @notice Swaps directly on Uniswap V2 pools (no router needed)
/// @dev Calculates amountOut from reserves, transfers tokenIn to pool, calls pool.swap()
contract UniV2DirectAdapter is IAdapter {
    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        IUniV2Pair pair = IUniV2Pair(pool);

        // Get reserves
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();

        bool zeroForOne = tokenIn == token0;
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // Calculate amountOut: dy = dx * 997 * reserveOut / (reserveIn * 1000 + dx * 997)
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

        // Transfer tokenIn directly to the pool
        TransferLib.safeTransfer(tokenIn, pool, amountIn);

        // Call swap
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        pair.swap(amount0Out, amount1Out, to, "");
    }
}
