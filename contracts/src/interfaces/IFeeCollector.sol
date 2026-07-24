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

    /// @notice Global default protocol fee in basis points (5 = 0.05%)
    function feeBps() external view returns (uint16);

    /// @notice Effective fee (bps) for a token — its per-token override if set, else the global default.
    ///         The router calls this on the OUTPUT token when settling a swap.
    function feeBpsFor(address token) external view returns (uint16);

    /// @notice Set a per-token fee override (0..MAX_FEE_BPS). Enables Jupiter-style tiering.
    function setTokenFeeBps(address token, uint16 bps) external;

    /// @notice Batch set per-token fee overrides (gas-efficient tiering).
    function setTokenFeeBpsBatch(address[] calldata tokens, uint16[] calldata bpsList) external;

    /// @notice Remove a per-token override → the token reverts to the global feeBps.
    function clearTokenFeeBps(address token) external;

    /// @notice Referral share in basis points (5000 = 50% of fee)
    function referralShareBps() external view returns (uint16);

    event FeeCollected(address indexed token, uint256 amount, address indexed referrer, uint256 referralAmount);
    event FeeWithdrawn(address indexed token, address indexed to, uint256 amount);
    event TokenFeeBpsSet(address indexed token, uint16 bps);
    event TokenFeeBpsCleared(address indexed token);
}
