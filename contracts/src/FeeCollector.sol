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
    /// @notice Absolute ceiling for ANY fee (global default or per-token override). Fees can never
    ///         exceed 1% — a hard, on-chain user-protection guarantee.
    uint16 public constant MAX_FEE_BPS = 100;

    uint16 public feeBps;
    uint16 public referralShareBps;
    address public treasury;

    /// @notice Accumulated fees per token: token → amount
    mapping(address => uint256) public accumulatedFees;

    /// @notice Only the NullRouter can call collectFee
    address public router;

    // ── Tiered fees (appended storage — preserves the pre-upgrade slot layout) ──
    /// @notice Per-token fee override, stored as `bps + 1` so 0 = "unset → fall back to the global
    ///         feeBps default". Lets an admin tier fees (higher on meme/new tokens, lower on majors)
    ///         without changing the default. A token with no override behaves exactly as before this
    ///         upgrade, so deploying the upgrade alone changes nothing until overrides are set.
    mapping(address => uint16) private _feeOverridePlus1;

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
        require(feeBps_ <= MAX_FEE_BPS, "FEE_TOO_HIGH"); // max 1%
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
        require(newFeeBps <= MAX_FEE_BPS, "FEE_TOO_HIGH");
        feeBps = newFeeBps;
    }

    // ============================================================
    // Tiered fees (per-token overrides)
    // ============================================================

    /// @inheritdoc IFeeCollector
    function feeBpsFor(address token) public view returns (uint16) {
        uint16 p = _feeOverridePlus1[token];
        return p == 0 ? feeBps : p - 1; // 0 = unset → global default
    }

    /// @inheritdoc IFeeCollector
    function setTokenFeeBps(address token, uint16 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "FEE_TOO_HIGH");
        _feeOverridePlus1[token] = bps + 1;
        emit TokenFeeBpsSet(token, bps);
    }

    /// @inheritdoc IFeeCollector
    function setTokenFeeBpsBatch(address[] calldata tokens, uint16[] calldata bpsList) external onlyOwner {
        require(tokens.length == bpsList.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(bpsList[i] <= MAX_FEE_BPS, "FEE_TOO_HIGH");
            _feeOverridePlus1[tokens[i]] = bpsList[i] + 1;
            emit TokenFeeBpsSet(tokens[i], bpsList[i]);
        }
    }

    /// @inheritdoc IFeeCollector
    function clearTokenFeeBps(address token) external onlyOwner {
        delete _feeOverridePlus1[token];
        emit TokenFeeBpsCleared(token);
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
