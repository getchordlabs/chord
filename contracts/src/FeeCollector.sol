// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {TransferLib} from "./libraries/TransferLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

/// @title FeeCollector
/// @notice Collects protocol fees (5 bps) and distributes referral rewards (50/50 split).
/// @dev UUPS upgradeable. Called by NullRouter after every swap.
///      ReentrancyGuard is STORAGE-SAFE to add to this live proxy: OZ 5.6.1's non-upgradeable guard
///      keeps its status in a fixed ERC-7201 namespaced slot, not a sequential one, so it adds
///      nothing to the layout (feeBps stays at slot 0). The implementation constructor sets
///      NOT_ENTERED on the impl only; the proxy reads 0, and the guard tests `== ENTERED`, so 0 is
///      correctly treated as not-entered. Same reasoning as NullRouter's existing guard.
contract FeeCollector is IFeeCollector, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
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

    // ── Fee manager (appended storage — preserves the pre-upgrade slot layout) ──
    /// @notice Optional least-privilege operator allowed to set/clear PER-TOKEN overrides only.
    /// @dev Exists so the automated fee-churn keeper can run without the owner key. The owner key
    ///      also authorises `_authorizeUpgrade` on the router/registry, so putting it on a shared
    ///      host would turn any host compromise into total protocol control. A stolen feeManager key
    ///      can only move per-token fees inside [0, MAX_FEE_BPS] — it cannot withdraw fees, change
    ///      the treasury/router, move the global default, or upgrade anything — and the owner
    ///      revokes it with `setFeeManager(address(0))`. Zero address = feature off (default).
    address public feeManager;

    error OnlyRouter();
    error ZeroAddress();
    error NotFeeAdmin();

    /// @notice Emitted when the least-privilege per-token fee operator changes (0 = revoked).
    event FeeManagerSet(address indexed feeManager);

    /// @notice Emitted when unledgered balance is swept out (L1 recovery path). Declared here rather
    ///         than in IFeeCollector: the interface is the router-facing contract and does not change.
    event UnaccountedSwept(address indexed token, address indexed to, uint256 amount);

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    /// @dev Owner, or the least-privilege fee manager when one is set. Guards PER-TOKEN overrides
    ///      ONLY — every other admin entrypoint stays strictly `onlyOwner`.
    modifier onlyFeeAdmin() {
        if (msg.sender != owner() && (feeManager == address(0) || msg.sender != feeManager)) {
            revert NotFeeAdmin();
        }
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
    function collectFee(address token, uint256 amount, address referrer) external onlyRouter nonReentrant {
        if (amount == 0) return;

        if (referrer != address(0) && referralShareBps > 0) {
            (uint256 referralAmount, uint256 treasuryAmount) =
                SwapMath.splitReferral(amount, referralShareBps);

            // INFO (2026-08-05 audit): checks-effects-INTERACTIONS. The referral payout is an
            // external call to a caller-supplied address, so the treasury credit is booked FIRST and
            // the transfer happens last. Not exploitable today (the only caller is onlyRouter and the
            // router is mid-nonReentrant), but the ordering plus the guard above means adding any
            // non-owner entrypoint later cannot turn this into a reentrancy hole.
            accumulatedFees[token] += treasuryAmount;

            // Transfer referral share directly to referrer
            if (referralAmount > 0) {
                TransferLib.safeTransfer(token, referrer, referralAmount);
            }

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

    /// @notice Sweep any balance of `token` this contract holds that the fee ledger does NOT account
    ///         for — i.e. `balanceOf(this) - accumulatedFees[token]`.
    /// @dev L1 (2026-08-05 audit): `withdrawFees` pays out of the LEDGER, so anything that arrives
    ///      without being booked is unrecoverable without a UUPS upgrade. That happens for real: a
    ///      swap naming this collector as its own `referrer` made the referral transfer a
    ///      self-transfer (net no-op) while only `treasuryAmount` was credited — measured at half the
    ///      fee stranded per such swap (PoC: test/AuditPoCReferrer.t.sol). The router now rejects that
    ///      reflexive referrer (H2), so this is the recovery path for what already accumulated, plus
    ///      cover for stray donations and fee-on-transfer rounding. Never touches booked fees:
    ///      subtracting the ledger first means treasury obligations cannot be swept out from under
    ///      `withdrawFees`.
    function sweepUnaccounted(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 held = IERC20(token).balanceOf(address(this));
        uint256 booked = accumulatedFees[token];
        require(held > booked, "NOTHING_UNACCOUNTED");
        uint256 amount = held - booked;

        TransferLib.safeTransfer(token, to, amount);

        emit UnaccountedSwept(token, to, amount);
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
    function setTokenFeeBps(address token, uint16 bps) external onlyFeeAdmin {
        require(bps <= MAX_FEE_BPS, "FEE_TOO_HIGH");
        _feeOverridePlus1[token] = bps + 1;
        emit TokenFeeBpsSet(token, bps);
    }

    /// @inheritdoc IFeeCollector
    function setTokenFeeBpsBatch(address[] calldata tokens, uint16[] calldata bpsList) external onlyFeeAdmin {
        require(tokens.length == bpsList.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(bpsList[i] <= MAX_FEE_BPS, "FEE_TOO_HIGH");
            _feeOverridePlus1[tokens[i]] = bpsList[i] + 1;
            emit TokenFeeBpsSet(tokens[i], bpsList[i]);
        }
    }

    /// @inheritdoc IFeeCollector
    function clearTokenFeeBps(address token) external onlyFeeAdmin {
        delete _feeOverridePlus1[token];
        emit TokenFeeBpsCleared(token);
    }

    /// @notice Grant/revoke the least-privilege per-token fee operator. Owner-only, revocable.
    function setFeeManager(address newFeeManager) external onlyOwner {
        feeManager = newFeeManager;
        emit FeeManagerSet(newFeeManager);
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
