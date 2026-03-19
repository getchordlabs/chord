// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {TransferLib} from "./libraries/TransferLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

/// @title FeeCollector
/// @notice Collects protocol fees (5 bps) and distributes referral rewards (50/50 split).
/// @dev UUPS upgradeable. Called by NullRouter after every swap.
contract FeeCollector is IFeeCollector, UUPSUpgradeable, OwnableUpgradeable {
    uint16 public feeBps;
    uint16 public referralShareBps;
    address public treasury;

    /// @notice Accumulated fees per token: token → amount
    mapping(address => uint256) public accumulatedFees;

    /// @notice Only the NullRouter can call collectFee
    address public router;

    error OnlyRouter();
    error ZeroAddress();

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address treasury_,
        address router_,
        uint16 feeBps_,
        uint16 referralShareBps_
    ) external initializer {
        __Ownable_init(owner_);

        require(treasury_ != address(0), "ZERO_TREASURY");
        require(router_ != address(0), "ZERO_ROUTER");
        require(feeBps_ <= 100, "FEE_TOO_HIGH"); // max 1%
        require(referralShareBps_ <= 10000, "SHARE_TOO_HIGH");

        treasury = treasury_;
        router = router_;
        feeBps = feeBps_;
        referralShareBps = referralShareBps_;
    }

    // ============================================================
    // Core
    // ============================================================

    /// @inheritdoc IFeeCollector
    function collectFee(address token, uint256 amount, address referrer) external onlyRouter {
        if (amount == 0) return;

        if (referrer != address(0) && referralShareBps > 0) {
            (uint256 referralAmount, uint256 treasuryAmount) =
                SwapMath.splitReferral(amount, referralShareBps);

            // Transfer referral share directly to referrer
            if (referralAmount > 0) {
                TransferLib.safeTransfer(token, referrer, referralAmount);
            }

            // Keep treasury share in this contract
            accumulatedFees[token] += treasuryAmount;

            emit FeeCollected(token, amount, referrer, referralAmount);
        } else {
            // No referrer: 100% to treasury
            accumulatedFees[token] += amount;
            emit FeeCollected(token, amount, address(0), 0);
        }
    }

    /// @inheritdoc IFeeCollector
    function withdrawFees(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = accumulatedFees[token];
        require(amount > 0, "NO_FEES");

        accumulatedFees[token] = 0;
        TransferLib.safeTransfer(token, to, amount);

        emit FeeWithdrawn(token, to, amount);
    }

    // ============================================================
    // Admin
    // ============================================================

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= 100, "FEE_TOO_HIGH");
        feeBps = newFeeBps;
    }

    function setReferralShareBps(uint16 newShareBps) external onlyOwner {
        require(newShareBps <= 10000, "SHARE_TOO_HIGH");
        referralShareBps = newShareBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "ZERO_ADDRESS");
        treasury = newTreasury;
    }

    function setRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "ZERO_ADDRESS");
        router = newRouter;
    }

    // ============================================================
    // UUPS
    // ============================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
