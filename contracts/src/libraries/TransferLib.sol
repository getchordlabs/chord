// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title TransferLib
/// @notice Safe ERC20 transfer helpers (handles non-standard tokens)
library TransferLib {
    error TransferFailed();
    error TransferFromFailed();
    error ApprovalFailed();

    /// @notice Safe transferFrom that handles tokens with no return value
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFromFailed();
        }
    }

    /// @notice Safe transfer that handles tokens with no return value
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Safe approve that handles tokens with no return value
    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert ApprovalFailed();
        }
    }
}
