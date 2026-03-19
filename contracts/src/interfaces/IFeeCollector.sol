// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title IFeeCollector
/// @notice Collects protocol fees and distributes referral rewards
interface IFeeCollector {
    /// @notice Collect fee from a swap
    /// @param token Output token address
    /// @param amount Fee amount
    /// @param referrer Referral address (address(0) if none)
    function collectFee(address token, uint256 amount, address referrer) external;

    /// @notice Withdraw accumulated fees to treasury
    /// @param token Token to withdraw
    /// @param to Treasury address
    function withdrawFees(address token, address to) external;

    /// @notice Protocol fee in basis points (5 = 0.05%)
    function feeBps() external view returns (uint16);

    /// @notice Referral share in basis points (5000 = 50% of fee)
    function referralShareBps() external view returns (uint16);

    event FeeCollected(address indexed token, uint256 amount, address indexed referrer, uint256 referralAmount);
    event FeeWithdrawn(address indexed token, address indexed to, uint256 amount);
}
