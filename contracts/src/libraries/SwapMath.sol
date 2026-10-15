// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SwapMath
/// @notice Math helpers for fee calculation and split routing
library SwapMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Calculate protocol fee amount
    /// @param amount Output amount before fee
    /// @param feeBps Fee in basis points (5 = 0.05%)
    /// @return fee Fee amount to collect
    function calculateFee(uint256 amount, uint256 feeBps) internal pure returns (uint256 fee) {
        fee = (amount * feeBps) / BPS_DENOMINATOR;
    }

    /// @notice Calculate referral split
    /// @param feeAmount Total fee amount
    /// @param referralShareBps Referral share in basis points (5000 = 50%)
    /// @return referralAmount Amount for referrer
    /// @return treasuryAmount Amount for treasury
    function splitReferral(uint256 feeAmount, uint256 referralShareBps)
        internal
        pure
        returns (uint256 referralAmount, uint256 treasuryAmount)
    {
        referralAmount = (feeAmount * referralShareBps) / BPS_DENOMINATOR;
        treasuryAmount = feeAmount - referralAmount;
    }
}
