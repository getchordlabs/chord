// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurveStableSwapNG {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

/// @title CurveAdapterNG
/// @notice Executes swaps on Curve StableSwap-NG pools via exchange(int128,int128,...).
/// @dev The original CurveAdapter targets the TwoCrypto flavor (uint256 indices) — but the live
///      Monad pools we route (BTC 3-pool, LST 4-pool) are StableSwap-NG, whose exchange takes
///      int128 indices (different selector; verified on-chain: get_dy(int128,...) succeeds and the
///      uint256 flavor reverts on both). extraData = abi.encode(address pool, int128 i, int128 j).
///      StableSwap-NG Factory: 0x8271e06E5887FE5ba05234f5315c19f3Ec90E8aD
contract CurveAdapterNG is IAdapter {
    /// @inheritdoc IAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        (address pool, int128 i, int128 j) = abi.decode(extraData, (address, int128, int128));

        TransferLib.safeApprove(tokenIn, pool, amountIn);
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        // minOut = 0 here: the NullRouter enforces the user's minOut on the FINAL output
        // (checks-effects pattern shared by every adapter).
        ICurveStableSwapNG(pool).exchange(i, j, amountIn, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        TransferLib.safeTransfer(tokenOut, to, amountOut);
        TransferLib.safeApprove(tokenIn, pool, 0);
    }
}
