// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";
import {IAdapterRegistry} from "./interfaces/IAdapterRegistry.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {NullExecutor} from "./NullExecutor.sol";
import {TransferLib} from "./libraries/TransferLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

/// @title NullRouter
/// @notice Entry point for all NullTerminal swaps. Handles token pulls, fee deduction, and dust sweeping.
/// @dev UUPS upgradeable. Users approve tokens to this contract.
///      Delegates execution to NullExecutor via delegatecall.
contract NullRouter is INullRouter, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    /// @notice WMON address on Monad
    address public wmon;

    /// @notice Executor contract (called via delegatecall)
    NullExecutor public executor;

    /// @notice Fee collector contract
    IFeeCollector public feeCollector;

    /// @notice Adapter registry (whitelist)
    IAdapterRegistry public registry;

    // ============================================================
    // Errors
    // ============================================================

    error Expired();
    error InsufficientOutput(uint256 got, uint256 minRequired);
    error ZeroAmount();
    error InvalidRoute();

    // ============================================================
    // Constructor + Initializer
    // ============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address wmon_,
        address executor_,
        address feeCollector_,
        address registry_
    ) external initializer {
        __Ownable_init(owner_);
        // ReentrancyGuard uses transient storage in OZ v5 — no init needed

        wmon = wmon_;
        executor = NullExecutor(executor_);
        feeCollector = IFeeCollector(feeCollector_);
        registry = IAdapterRegistry(registry_);
    }

    // ============================================================
    // Swap Functions
    // ============================================================

    /// @inheritdoc INullRouter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep calldata route,
        address referrer
    ) external payable nonReentrant returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();

        // 1. Pull input tokens from user
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute swap via executor (delegatecall)
        amountOut = _executeSingle(route);

        // 3. Deduct fee + deliver output
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer);

        // 4. Sweep dust
        _sweepDust(tokenIn);
        _sweepDust(tokenOut);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    /// @inheritdoc INullRouter
    function splitSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer
    ) external payable nonReentrant returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (routes.length == 0) revert InvalidRoute();

        // 1. Pull input tokens
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute split via executor
        amountOut = _executeSplit(tokenIn, tokenOut, routes);

        // 3. Deduct fee + deliver output
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer);

        // 4. Sweep dust
        _sweepDust(tokenIn);
        _sweepDust(tokenOut);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    /// @inheritdoc INullRouter
    function multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer
    ) external payable nonReentrant returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (routes.length < 2) revert InvalidRoute();

        address tokenIn = routes[0].tokenIn;
        address tokenOut = routes[routes.length - 1].tokenOut;

        // 1. Pull input tokens
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute multi-hop via executor
        amountOut = _executeMultiHop(routes);

        // 3. Deduct fee + deliver output
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer);

        // 4. Sweep dust (all intermediate + final tokens)
        _sweepDust(tokenIn);
        for (uint256 i = 0; i < routes.length; i++) {
            _sweepDust(routes[i].tokenOut);
        }

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    // ============================================================
    // Internal: Token Handling
    // ============================================================

    /// @dev Temporary storage for last fee amount (for event emission)
    uint256 private _lastFeeAmount;

    function _pullTokens(address token, address from, uint256 amount) internal {
        if (msg.value > 0 && token == wmon) {
            // Native MON: wrap to WMON
            require(msg.value == amount, "MON_AMOUNT_MISMATCH");
            IWMON(wmon).deposit{value: amount}();
        } else {
            // ERC20: transferFrom
            TransferLib.safeTransferFrom(token, from, address(this), amount);
        }
    }

    function _settleOutput(
        address tokenOut,
        uint256 rawOutput,
        uint256 minAmountOut,
        address referrer
    ) internal returns (uint256 userOutput) {
        // Calculate fee
        uint256 feeAmount = SwapMath.calculateFee(rawOutput, feeCollector.feeBps());
        userOutput = rawOutput - feeAmount;

        // Check slippage
        if (userOutput < minAmountOut) {
            revert InsufficientOutput(userOutput, minAmountOut);
        }

        // Send fee to collector
        if (feeAmount > 0) {
            TransferLib.safeTransfer(tokenOut, address(feeCollector), feeAmount);
            feeCollector.collectFee(tokenOut, feeAmount, referrer);
        }

        // Send output to user
        TransferLib.safeTransfer(tokenOut, msg.sender, userOutput);

        _lastFeeAmount = feeAmount;
    }

    /// @dev Sweep any remaining tokens to the user. Router must hold 0 tokens.
    function _sweepDust(address token) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            TransferLib.safeTransfer(token, msg.sender, balance);
        }
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
    }

    // ============================================================
    // Internal: Execution (delegatecall to NullExecutor)
    // ============================================================

    function _executeSingle(RouteStep calldata route) internal returns (uint256) {
        (bool success, bytes memory result) = address(executor).delegatecall(
            abi.encodeCall(NullExecutor.executeSingle, (route, registry))
        );
        require(success, "EXECUTOR_FAILED");
        return abi.decode(result, (uint256));
    }

    function _executeSplit(
        address tokenIn,
        address tokenOut,
        RouteStep[] calldata routes
    ) internal returns (uint256) {
        (bool success, bytes memory result) = address(executor).delegatecall(
            abi.encodeCall(NullExecutor.executeSplit, (tokenIn, tokenOut, routes, registry))
        );
        require(success, "EXECUTOR_FAILED");
        return abi.decode(result, (uint256));
    }

    function _executeMultiHop(RouteStep[] calldata routes) internal returns (uint256) {
        (bool success, bytes memory result) = address(executor).delegatecall(
            abi.encodeCall(NullExecutor.executeMultiHop, (routes, registry))
        );
        require(success, "EXECUTOR_FAILED");
        return abi.decode(result, (uint256));
    }

    // ============================================================
    // Admin
    // ============================================================

    function setExecutor(address newExecutor) external onlyOwner {
        executor = NullExecutor(newExecutor);
    }

    function setFeeCollector(address newFeeCollector) external onlyOwner {
        feeCollector = IFeeCollector(newFeeCollector);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        registry = IAdapterRegistry(newRegistry);
    }

    /// @dev Emergency: rescue stuck tokens (should never happen)
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            TransferLib.safeTransfer(token, to, balance);
        }
    }

    /// @dev Accept native MON for wrapping
    receive() external payable {}

    // ============================================================
    // UUPS
    // ============================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/// @dev Minimal WMON interface for wrap/unwrap
interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
