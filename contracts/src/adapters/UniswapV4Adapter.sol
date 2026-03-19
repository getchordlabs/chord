// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title UniswapV4Adapter
/// @notice Executes swaps on Uniswap V4 via UniversalRouter on Monad
/// @dev Immutable (no proxy). Stateless. Route: approve → UniversalRouter.execute()
///
/// Uniswap V4 on Monad:
///   PoolManager:     0x188d586ddcf52439676ca21a244753fa19f9ea8e
///   UniversalRouter: 0x0d97dc33264bfc1c226207428a79b26757fb9dc3
///   Permit2:         0x000000000022D473030F116dDEE9F6B43aC78BA3
contract UniswapV4Adapter is IAdapter {
    /// @notice Uniswap V4 UniversalRouter address on Monad
    address public immutable universalRouter;

    /// @notice Permit2 address (canonical across all EVM chains)
    address public immutable permit2;

    error SwapFailed();
    error ZeroOutput();

    constructor(address universalRouter_, address permit2_) {
        universalRouter = universalRouter_;
        permit2 = permit2_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(bytes commands, bytes[] inputs, uint256 deadline)
    ///      The commands + inputs are pre-built by the Rust engine for the specific pool.
    ///      This adapter just approves tokens and forwards to UniversalRouter.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        // Decode UniversalRouter execute params
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) =
            abi.decode(extraData, (bytes, bytes[], uint256));

        // Approve Permit2 to spend tokenIn (UniversalRouter uses Permit2)
        TransferLib.safeApprove(tokenIn, permit2, amountIn);

        // Approve UniversalRouter via Permit2
        // For simplicity, also approve UniversalRouter directly
        TransferLib.safeApprove(tokenIn, universalRouter, amountIn);

        // Record output token balance before swap
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap via UniversalRouter
        (bool success,) = universalRouter.call(
            abi.encodeWithSignature(
                "execute(bytes,bytes[],uint256)",
                commands,
                inputs,
                deadline
            )
        );
        if (!success) revert SwapFailed();

        // Calculate output
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;
        if (amountOut == 0) revert ZeroOutput();

        // Transfer output to recipient
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Reset approvals
        TransferLib.safeApprove(tokenIn, permit2, 0);
        TransferLib.safeApprove(tokenIn, universalRouter, 0);
    }
}
