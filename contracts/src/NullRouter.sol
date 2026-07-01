// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";
import {IAdapterRegistry} from "./interfaces/IAdapterRegistry.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {TransferLib} from "./libraries/TransferLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

interface IPermit2 {
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/// @title NullRouter
/// @notice Entry point for all NullTerminal swaps. Handles token pulls, fee deduction, and dust sweeping.
/// @dev UUPS upgradeable. Users approve tokens to this contract.
///      Delegates execution to NullExecutor via delegatecall.
contract NullRouter is INullRouter, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    /// @notice WMON address on Monad
    address public wmon;

    /// @notice Executor contract (deprecated — kept for storage layout compatibility)
    address public executor;

    /// @notice Fee collector contract
    IFeeCollector public feeCollector;

    /// @notice Adapter registry (whitelist)
    IAdapterRegistry public registry;

    /// @notice Permit2 contract (canonical address on all EVM chains)
    IPermit2 public permit2;

    // ============================================================
    // Errors
    // ============================================================

    error Expired();
    error InsufficientOutput(uint256 got, uint256 minRequired);
    error ZeroAmount();
    error InvalidRoute();
    error NativeTransferFailed();

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
        // L3: ReentrancyGuard here is the standard storage-slot guard (OZ
        // ReentrancyGuard via StorageSlot, NOT EIP-1153 transient storage). For a
        // proxy the default slot value is 0, which the guard treats as NOT_ENTERED,
        // so no explicit initialization is required.

        wmon = wmon_;
        executor = executor_;
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
        // Native-MON output sentinel: tokenOut == address(0) means "deliver native MON". The swap
        // itself produces WMON, unwrapped at settlement; map to WMON for all ERC20-level ops.
        bool nativeOut = tokenOut == address(0);
        address outToken = nativeOut ? wmon : tokenOut;
        // L2: route must move the function-level token pair
        if (route.tokenIn != tokenIn || route.tokenOut != outToken) revert InvalidRoute();
        // L1: single route must consume exactly amountIn
        if (route.amountIn != amountIn) revert InvalidRoute();

        // H1: snapshot pre-existing router balances so only swap-generated dust is swept
        uint256 baseIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 baseOut = IERC20(outToken).balanceOf(address(this));

        // 1. Pull input tokens from user
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute swap via executor (delegatecall)
        amountOut = _executeSingle(route);

        // 3. Deduct fee + deliver output (unwrap to native MON if requested)
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut);

        // 4. Sweep dust above the pre-swap baseline (never the pre-existing balance)
        _sweepDustDelta(tokenIn, baseIn);
        _sweepDustDelta(outToken, baseOut);

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

        // Native-MON output sentinel (see swap): tokenOut == address(0) → deliver native MON.
        bool nativeOut = tokenOut == address(0);
        address outToken = nativeOut ? wmon : tokenOut;

        // L1/L2: every route must move the function-level pair and the per-route
        // amounts must sum to exactly amountIn (no over/under-pulling vs. user intent)
        uint256 sumIn;
        for (uint256 i = 0; i < routes.length; i++) {
            if (routes[i].tokenIn != tokenIn || routes[i].tokenOut != outToken) revert InvalidRoute();
            sumIn += routes[i].amountIn;
        }
        if (sumIn != amountIn) revert InvalidRoute();

        // H1: snapshot pre-existing router balances so only swap-generated dust is swept
        uint256 baseIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 baseOut = IERC20(outToken).balanceOf(address(this));

        // 1. Pull input tokens
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute split via executor
        amountOut = _executeSplit(tokenIn, outToken, routes);

        // 3. Deduct fee + deliver output (unwrap to native MON if requested)
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut);

        // 4. Sweep dust above the pre-swap baseline (never the pre-existing balance)
        _sweepDustDelta(tokenIn, baseIn);
        _sweepDustDelta(outToken, baseOut);

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
        // Backward-compatible: delivers routes[last].tokenOut as-is (WMON stays WMON).
        return _multiHopSwap(amountIn, minAmountOut, deadline, routes, referrer, false);
    }

    /// @notice Multi-hop swap with optional native-MON delivery.
    /// @dev When `unwrapOutput` is true, the final hop MUST produce WMON, which is unwrapped and
    ///      forwarded to the caller as native MON. This is the multi-hop counterpart of the
    ///      `tokenOut == address(0)` sentinel used by swap/splitSwap. NOT in INullRouter (overload).
    function multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer,
        bool unwrapOutput
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _multiHopSwap(amountIn, minAmountOut, deadline, routes, referrer, unwrapOutput);
    }

    function _multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer,
        bool unwrapOutput
    ) internal returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (routes.length < 2) revert InvalidRoute();

        address tokenIn = routes[0].tokenIn;
        address tokenOut = routes[routes.length - 1].tokenOut;
        // Native output requires the final hop to produce WMON (which we unwrap at settlement).
        if (unwrapOutput && tokenOut != wmon) revert InvalidRoute();

        // L1: first hop must consume exactly amountIn (subsequent hops chain the prior
        // hop's output, so only the entry amount is constrained here). Per-hop token
        // pairs legitimately differ, so they are NOT constrained (see L2).
        if (routes[0].amountIn != amountIn) revert InvalidRoute();

        // H1: snapshot pre-existing balances for tokenIn + every hop's tokenOut
        // (intermediates + final) BEFORE pulling, so only swap-generated dust is swept.
        // Snapshotting per target (rather than before the loop) keeps the baseline correct
        // even when the same token recurs across hops.
        uint256[] memory baselines = new uint256[](routes.length + 1);
        baselines[0] = IERC20(tokenIn).balanceOf(address(this));
        for (uint256 i = 0; i < routes.length; i++) {
            baselines[i + 1] = IERC20(routes[i].tokenOut).balanceOf(address(this));
        }

        // 1. Pull input tokens
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute multi-hop via executor
        amountOut = _executeMultiHop(routes);

        // 3. Deduct fee + deliver output (unwrap to native MON if requested)
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer, unwrapOutput);

        // 4. Sweep dust above baseline (all intermediate + final tokens)
        _sweepDustDelta(tokenIn, baselines[0]);
        for (uint256 i = 0; i < routes.length; i++) {
            _sweepDustDelta(routes[i].tokenOut, baselines[i + 1]);
        }

        // For native output, emit address(0) as tokenOut to signal native delivery.
        emit Swap(msg.sender, tokenIn, unwrapOutput ? address(0) : tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    // ============================================================
    // Permit2 Swap (gasless approval)
    // ============================================================

    /// @notice Swap with Permit2 signature (no prior approval needed)
    function swapPermit2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep calldata route,
        address referrer,
        uint256 nonce,
        uint256 permitDeadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        // Native-MON output sentinel (see swap): tokenOut == address(0) → deliver native MON.
        bool nativeOut = tokenOut == address(0);
        address outToken = nativeOut ? wmon : tokenOut;
        // L2: route must move the function-level token pair
        if (route.tokenIn != tokenIn || route.tokenOut != outToken) revert InvalidRoute();
        // L1: single route must consume exactly amountIn
        if (route.amountIn != amountIn) revert InvalidRoute();

        // H1: snapshot pre-existing router balances so only swap-generated dust is swept
        uint256 baseIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 baseOut = IERC20(outToken).balanceOf(address(this));

        // Pull via Permit2
        _pullTokensPermit2(tokenIn, msg.sender, amountIn, nonce, permitDeadline, signature);

        amountOut = _executeSingle(route);
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut);

        _sweepDustDelta(tokenIn, baseIn);
        _sweepDustDelta(outToken, baseOut);

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
            // ERC20 (incl. WMON-as-ERC20). Reject any attached native value: the payable entrypoints +
            // empty receive() would otherwise silently swallow it with NO refund and NO rescue path
            // (rescueTokens only reads IERC20.balanceOf) → permanently stuck user funds.
            require(msg.value == 0, "UNEXPECTED_VALUE");
            TransferLib.safeTransferFrom(token, from, address(this), amount);
        }
    }

    function _pullTokensPermit2(
        address token,
        address from,
        uint256 amount,
        uint256 nonce,
        uint256 permitDeadline,
        bytes calldata signature
    ) internal {
        permit2.permitTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({
                    token: token,
                    amount: amount
                }),
                nonce: nonce,
                deadline: permitDeadline
            }),
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: amount
            }),
            from,
            signature
        );
    }

    function _settleOutput(
        address tokenOut,
        uint256 rawOutput,
        uint256 minAmountOut,
        address referrer,
        bool unwrapNative
    ) internal returns (uint256 userOutput) {
        // Calculate fee
        uint256 feeAmount = SwapMath.calculateFee(rawOutput, feeCollector.feeBps());
        userOutput = rawOutput - feeAmount;

        // Check slippage
        if (userOutput < minAmountOut) {
            revert InsufficientOutput(userOutput, minAmountOut);
        }

        // Send fee to collector. Drop a self-referral (referrer == swapper) so the user cannot claw
        // back 50% of their own fee → treasury keeps the whole fee. NOTE: a determined user can still
        // refer from a second wallet (Sybil); fully closing that needs an owner-managed referrer
        // allowlist, which would break open third-party referral — intentionally left open.
        if (feeAmount > 0) {
            address ref = referrer == msg.sender ? address(0) : referrer;
            TransferLib.safeTransfer(tokenOut, address(feeCollector), feeAmount);
            feeCollector.collectFee(tokenOut, feeAmount, ref);
        }

        // Send output to user. For a native-MON output the swap produced WMON (tokenOut == wmon,
        // enforced by callers): unwrap the user's portion and forward native MON. The fee above stays
        // in WMON to the collector. nonReentrant on every entrypoint guards the native .call.
        if (unwrapNative) {
            IWMON(wmon).withdraw(userOutput);
            (bool ok, ) = payable(msg.sender).call{value: userOutput}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            TransferLib.safeTransfer(tokenOut, msg.sender, userOutput);
        }

        _lastFeeAmount = feeAmount;
    }

    /// @dev Sweep only the dust generated by THIS swap back to the user.
    ///      H1: sweeps `currentBalance - baseline` (floored at 0), where `baseline` was
    ///      snapshotted at function entry. Any pre-existing router balance (donations,
    ///      adapter over-delivery from prior txs, pending rescueTokens) stays untouched
    ///      so it cannot be stolen by the next swapper.
    function _sweepDustDelta(address token, uint256 baseline) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > baseline) {
            TransferLib.safeTransfer(token, msg.sender, balance - baseline);
        }
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
    }

    // ============================================================
    // Internal: Execution (direct adapter calls — no delegatecall)
    // ============================================================

    function _executeSingle(RouteStep calldata route) internal returns (uint256) {
        _validateAdapter(route.adapter);

        // Transfer tokens to adapter
        TransferLib.safeTransfer(route.tokenIn, route.adapter, route.amountIn);

        // Execute swap via adapter
        return IAdapter(route.adapter).swap(
            route.tokenIn,
            route.tokenOut,
            route.amountIn,
            address(this),
            route.extraData
        );
    }

    function _executeSplit(
        address tokenIn,
        address tokenOut,
        RouteStep[] calldata routes
    ) internal returns (uint256 totalOut) {
        for (uint256 i = 0; i < routes.length; i++) {
            _validateAdapter(routes[i].adapter);
            TransferLib.safeTransfer(tokenIn, routes[i].adapter, routes[i].amountIn);
            totalOut += IAdapter(routes[i].adapter).swap(
                tokenIn, tokenOut, routes[i].amountIn, address(this), routes[i].extraData
            );
        }
    }

    function _executeMultiHop(RouteStep[] calldata routes) internal returns (uint256 amountOut) {
        require(routes.length >= 2, "MIN_2_HOPS");
        for (uint256 i = 0; i < routes.length; i++) {
            _validateAdapter(routes[i].adapter);
            // Hop continuity: hop i must consume exactly what hop i-1 produced. Without this, the
            // forwarded amount (`amountOut` of the prior hop) is decoupled from `routes[i].tokenIn`,
            // letting a caller push the router's standing balance of an ARBITRARY token through a
            // whitelisted adapter and sweep the proceeds — draining any leftover/donated/over-delivered
            // tokens and bypassing the H1 dust-baseline guard. (routes[0].tokenIn is constrained by the
            // entrypoint, which pulls amountIn of it.)
            if (i > 0) {
                require(routes[i].tokenIn == routes[i - 1].tokenOut, "HOP_TOKEN_MISMATCH");
            }
            uint256 amtIn = i == 0 ? routes[i].amountIn : amountOut;
            TransferLib.safeTransfer(routes[i].tokenIn, routes[i].adapter, amtIn);
            amountOut = IAdapter(routes[i].adapter).swap(
                routes[i].tokenIn, routes[i].tokenOut, amtIn, address(this), routes[i].extraData
            );
        }
    }

    function _validateAdapter(address adapter) internal view {
        require(registry.isApproved(adapter), "UNAPPROVED_ADAPTER");
    }

    // ============================================================
    // Admin
    // ============================================================

    function setExecutor(address newExecutor) external onlyOwner {
        executor = newExecutor;
    }

    function setFeeCollector(address newFeeCollector) external onlyOwner {
        feeCollector = IFeeCollector(newFeeCollector);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        registry = IAdapterRegistry(newRegistry);
    }

    function setPermit2(address newPermit2) external onlyOwner {
        permit2 = IPermit2(newPermit2);
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
