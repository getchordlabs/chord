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

    /// @dev Temporary storage for last fee amount (for event emission). SLOT 5.
    ///      L3 (2026-08-05 audit): this declaration used to sit ~360 lines below, in the middle of
    ///      the contract, invisible from the state block at the top of the file. The trap sprang
    ///      TWICE — 4d1e2fa inserted `executor` at slot 1 and bc870ac inserted `permit2` at what was
    ///      then this variable's slot — silently corrupting the fee value carried into the Swap
    ///      event on a LIVE proxy. Moved here AT ITS CURRENT SLOT (6th declared var → slot 5); the
    ///      order of every variable above is unchanged, so the on-chain layout is byte-identical.
    uint256 private _lastFeeAmount;

    // ⚠️ APPEND ONLY BELOW — see docs/audit-contracts-2026-08-05.md (L3).
    // This is a UUPS proxy: NEVER insert or reorder a state variable above this line. New state goes
    // here, at the end, and nowhere else. There is no __gap and no automated layout check yet.

    // ============================================================
    // Constants
    // ============================================================

    /// @notice Absolute ceiling the ROUTER itself will pay in fee, in bps (1%).
    /// @dev L2 (2026-08-05 audit): FeeCollector.MAX_FEE_BPS is documented as "a hard, on-chain
    ///      user-protection guarantee", but it lives inside a contract that is both upgradeable AND
    ///      replaceable wholesale via setFeeCollector. A single owner tx pointing at a collector that
    ///      returns 10000 would make every swap with minAmountOut == 0 pay out nothing. This constant
    ///      is compiled into the router (only an upgrade of the ROUTER can change it), so the
    ///      guarantee no longer depends on the collector's own honesty.
    uint16 private constant MAX_FEE_BPS = 100;

    // ============================================================
    // Errors
    // ============================================================

    error Expired();
    error InsufficientOutput(uint256 got, uint256 minRequired);
    error ZeroAmount();
    error InvalidRoute();
    error NativeTransferFailed();
    error ZeroAddress();

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

        // H2: the swap's true beneficiary (msg.sender for a direct call, the declared principal for
        // an intermediary) — resolved BEFORE any external call so the referral guard can't be raced.
        address swapper = _resolveSwapper();

        // 1. Pull input tokens from user
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute swap via executor (delegatecall)
        amountOut = _executeSingle(route);

        // 3. Deduct fee + deliver output (unwrap to native MON if requested)
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut, swapper);

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

        // H2: see swap() — resolve the true beneficiary for the referral guard.
        address swapper = _resolveSwapper();

        // 1. Pull input tokens
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Execute split via executor
        amountOut = _executeSplit(tokenIn, outToken, routes);

        // 3. Deduct fee + deliver output (unwrap to native MON if requested)
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut, swapper);

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
        return _multiHopSwap(amountIn, minAmountOut, deadline, routes, referrer, false, _resolveSwapper());
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
        return _multiHopSwap(amountIn, minAmountOut, deadline, routes, referrer, unwrapOutput, _resolveSwapper());
    }

    /// @inheritdoc INullRouter
    function multiPathSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Path[] calldata paths,
        address referrer
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _multiPathSwap(amountIn, minAmountOut, deadline, paths, referrer, false, _resolveSwapper());
    }

    /// @notice Multi-path swap with optional native-MON delivery (WMON final output unwrapped).
    /// @dev Counterpart of the multiHopSwap unwrap overload. NOT in INullRouter (overload).
    function multiPathSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Path[] calldata paths,
        address referrer,
        bool unwrapOutput
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _multiPathSwap(amountIn, minAmountOut, deadline, paths, referrer, unwrapOutput, _resolveSwapper());
    }

    function _multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        RouteStep[] calldata routes,
        address referrer,
        bool unwrapOutput,
        address swapper
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
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer, unwrapOutput, swapper);

        // 4. Sweep dust above baseline (all intermediate + final tokens)
        _sweepDustDelta(tokenIn, baselines[0]);
        for (uint256 i = 0; i < routes.length; i++) {
            _sweepDustDelta(routes[i].tokenOut, baselines[i + 1]);
        }

        // For native output, emit address(0) as tokenOut to signal native delivery.
        emit Swap(msg.sender, tokenIn, unwrapOutput ? address(0) : tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    /// @dev Multi-PATH execution: the input splits across 2+ independent hop chains (e.g. 60%
    ///      direct pool + 40% via a multi-hop detour through a different pool), outputs are summed,
    ///      and fee + minAmountOut apply ONCE to the total. Mirrors _multiHopSwap's flow exactly
    ///      (validate → H1 baselines → pull once → execute → settle once → sweep); each path chain
    ///      reuses _executeSingle / _executeMultiHop, so the per-hop adapter whitelist and the
    ///      hop-continuity guard (audit dff96f8) apply unchanged.
    function _multiPathSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        Path[] calldata paths,
        address referrer,
        bool unwrapOutput,
        address swapper
    ) internal returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        // 1 path = plain swap/multiHopSwap — use those entrypoints. Multi-path is 2+.
        if (paths.length < 2) revert InvalidRoute();

        address tokenIn = paths[0].hops[0].tokenIn;
        address tokenOut = paths[0].hops[paths[0].hops.length - 1].tokenOut;
        if (unwrapOutput && tokenOut != wmon) revert InvalidRoute();

        // Validate every path: shares the entry/exit tokens, entry hop consumes exactly its
        // declared share, and the shares sum to amountIn (no free-riding on router balances).
        uint256 declared;
        uint256 totalHops;
        for (uint256 p = 0; p < paths.length; p++) {
            RouteStep[] calldata hops = paths[p].hops;
            if (hops.length == 0) revert InvalidRoute();
            if (hops[0].tokenIn != tokenIn) revert InvalidRoute();
            if (hops[hops.length - 1].tokenOut != tokenOut) revert InvalidRoute();
            if (hops[0].amountIn != paths[p].amountIn || paths[p].amountIn == 0) revert InvalidRoute();
            declared += paths[p].amountIn;
            totalHops += hops.length;
        }
        if (declared != amountIn) revert InvalidRoute();

        // H1: baselines for tokenIn + every hop tokenOut across ALL paths, snapshotted BEFORE the
        // pull so only swap-generated dust is swept (same token recurring is fine — after the first
        // sweep restores its baseline, later sweeps of it are no-ops).
        uint256[] memory baselines = new uint256[](totalHops + 1);
        baselines[0] = IERC20(tokenIn).balanceOf(address(this));
        {
            uint256 b = 1;
            for (uint256 p = 0; p < paths.length; p++) {
                for (uint256 h = 0; h < paths[p].hops.length; h++) {
                    baselines[b++] = IERC20(paths[p].hops[h].tokenOut).balanceOf(address(this));
                }
            }
        }

        // 1. Pull the TOTAL input once
        _pullTokens(tokenIn, msg.sender, amountIn);

        // 2. Run each path as its own chain, summing outputs
        for (uint256 p = 0; p < paths.length; p++) {
            amountOut += paths[p].hops.length == 1
                ? _executeSingle(paths[p].hops[0])
                : _executeMultiHop(paths[p].hops);
        }

        // 3. Fee + slippage ONCE on the total
        amountOut = _settleOutput(tokenOut, amountOut, minAmountOut, referrer, unwrapOutput, swapper);

        // 4. Sweep dust above every baseline
        _sweepDustDelta(tokenIn, baselines[0]);
        {
            uint256 b = 1;
            for (uint256 p = 0; p < paths.length; p++) {
                for (uint256 h = 0; h < paths[p].hops.length; h++) {
                    _sweepDustDelta(paths[p].hops[h].tokenOut, baselines[b++]);
                }
            }
        }

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

        // H2: see swap() — resolve the true beneficiary for the referral guard.
        address swapper = _resolveSwapper();

        // Pull via Permit2
        _pullTokensPermit2(tokenIn, msg.sender, amountIn, nonce, permitDeadline, signature);

        amountOut = _executeSingle(route);
        amountOut = _settleOutput(outToken, amountOut, minAmountOut, referrer, nativeOut, swapper);

        _sweepDustDelta(tokenIn, baseIn);
        _sweepDustDelta(outToken, baseOut);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, _lastFeeAmount, referrer);
    }

    // ============================================================
    // Internal: Token Handling
    // ============================================================

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

    /// @dev Resolve the party the swap is FOR — the beneficiary the self-referral guard must be
    ///      measured against.
    ///
    ///      H2 (2026-08-05 audit), second defect: `_settleOutput` compared `referrer` against
    ///      `msg.sender`, which is the INTERMEDIARY (GaslessEntry, GaslessEntryPermit2, the order
    ///      book, the executors) for every contract-mediated swap — never the person whose funds
    ///      moved. The guard was therefore structurally dead there: a gasless order could simply set
    ///      `referrer = o.user` and hand the user back half their own fee.
    ///
    ///      An intermediary declares its principal by exposing `currentSwapper()`; anything that does
    ///      not (an EOA, or a contract that has not opted in) falls back to `msg.sender`, which is the
    ///      correct answer for a direct user call. The hook is deliberately UNTRUSTED: `swapper` is
    ///      only ever used to DROP a referral, so a lying intermediary gains nothing it could not
    ///      already get by naming a second wallet (the Sybil case documented below).
    function _resolveSwapper() internal view returns (address) {
        if (msg.sender.code.length == 0) return msg.sender;
        (bool ok, bytes memory ret) =
            msg.sender.staticcall(abi.encodeWithSelector(ISwapperContext.currentSwapper.selector));
        if (ok && ret.length == 32) {
            // Decode defensively: a stray fallback returning 32 bytes of junk must NOT revert the
            // swap, so reject dirty upper bits instead of using abi.decode(...,(address)).
            uint256 word = uint256(abi.decode(ret, (bytes32)));
            // The `word >> 160 == 0` check is what makes the uint160 cast lossless.
            if (word >> 160 == 0 && word != 0) return address(uint160(word));
        }
        return msg.sender;
    }

    function _settleOutput(
        address tokenOut,
        uint256 rawOutput,
        uint256 minAmountOut,
        address referrer,
        bool unwrapNative,
        address swapper
    ) internal returns (uint256 userOutput) {
        // Calculate fee. Tiered by the OUTPUT token: a token with no override resolves to the global
        // default (feeBps), so this is behaviour-preserving until per-token overrides are set. Charging
        // on the output token means meme BUYS (output = meme) pay the premium tier while SELLS back to a
        // major (output = major) stay cheap — intentional: don't punish exits.
        // L2: the router enforces its OWN ceiling on whatever the (upgradeable, replaceable) collector
        // reports, so a swapped-in collector cannot confiscate the output of a minAmountOut == 0 swap.
        uint16 bps = feeCollector.feeBpsFor(tokenOut);
        require(bps <= MAX_FEE_BPS, "FEE_TOO_HIGH");
        uint256 feeAmount = SwapMath.calculateFee(rawOutput, bps);
        userOutput = rawOutput - feeAmount;

        // Check slippage
        if (userOutput < minAmountOut) {
            revert InsufficientOutput(userOutput, minAmountOut);
        }

        // Send fee to collector. Drop a REFLEXIVE referral so no one can claw back the referral half
        // of their own fee → treasury keeps the whole fee. Four addresses are reflexive:
        //   • swapper       — the beneficiary (see _resolveSwapper; for a direct call == msg.sender)
        //   • msg.sender    — the caller; for an intermediary the referral half lands in it and is
        //                     forwarded to the user with the rest of the proceeds
        //   • address(this) — H2, LIVE LEAK: FeeCollector paid the referral half back INTO the router,
        //                     where _sweepDustDelta then forwarded it to msg.sender. A permissionless
        //                     50% fee rebate, one tx, no second wallet (PoC: AuditPoCReferrer)
        //   • feeCollector  — L1: the referral transfer becomes a self-transfer that the ledger never
        //                     books, stranding half the fee (recoverable via sweepUnaccounted)
        // NOTE: a determined user can still refer from a second wallet (Sybil); fully closing that
        // needs an owner-managed referrer allowlist, which would break open third-party referral —
        // intentionally left open.
        if (feeAmount > 0) {
            address ref = referrer;
            if (
                ref == swapper || ref == msg.sender || ref == address(this) || ref == address(feeCollector)
            ) {
                ref = address(0);
            }
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

    // M1 (2026-08-05 audit): every hop's output below is a MEASURED balance delta, never the
    // adapter's self-reported return value.
    //
    // Why: fee and payout were computed from what the adapter CLAIMED it delivered. When an adapter
    // delivered less (a hostile pool named in extraData — H1 — or simply a buggy one), the shortfall
    // was silently covered out of whatever the router happened to be holding: the post-settlement
    // balance ended BELOW the H1 baseline, so _sweepDustDelta became a no-op and nothing reverted.
    // multiPathSwap amplified it, because earlier paths' proceeds sit in the router while later paths
    // run. PoC: test/AuditPoC.t.sol.
    //
    // Chosen over the cheaper `require(balanceOf >= baseline + rawOutput)` alternative in
    // _settleOutput: measuring costs one extra balanceOf pair per hop (the token is already warm from
    // the safeTransfer immediately above), and it is strictly stronger — with a measured delta that
    // invariant holds by construction, so the require would be dead code. Measuring also makes
    // fee-on-transfer OUTPUT tokens work for the first time (the live blocker in plan.md): the router
    // now settles on what actually landed rather than on the pre-tax number, instead of over-paying
    // the user out of its own balance and reverting on the transfer.
    //
    // The snapshot is taken AFTER the input transfer to the adapter, so a route whose tokenIn ==
    // tokenOut measures the swap's effect only.
    function _executeSingle(RouteStep calldata route) internal returns (uint256) {
        _validateAdapter(route.adapter);

        // Transfer tokens to adapter
        TransferLib.safeTransfer(route.tokenIn, route.adapter, route.amountIn);

        // Execute swap via adapter — the return value is deliberately IGNORED (see above)
        uint256 balBefore = IERC20(route.tokenOut).balanceOf(address(this));
        IAdapter(route.adapter).swap(
            route.tokenIn,
            route.tokenOut,
            route.amountIn,
            address(this),
            route.extraData
        );
        return IERC20(route.tokenOut).balanceOf(address(this)) - balBefore;
    }

    function _executeSplit(
        address tokenIn,
        address tokenOut,
        RouteStep[] calldata routes
    ) internal returns (uint256 totalOut) {
        for (uint256 i = 0; i < routes.length; i++) {
            _validateAdapter(routes[i].adapter);
            TransferLib.safeTransfer(tokenIn, routes[i].adapter, routes[i].amountIn);
            // M1: measured delta per route, not the adapter's claim.
            uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
            IAdapter(routes[i].adapter).swap(
                tokenIn, tokenOut, routes[i].amountIn, address(this), routes[i].extraData
            );
            totalOut += IERC20(tokenOut).balanceOf(address(this)) - balBefore;
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
            // M1: measured delta per hop. The next hop then forwards an amount the router provably
            // holds, so an over-reporting hop can no longer borrow the router's standing balance.
            uint256 balBefore = IERC20(routes[i].tokenOut).balanceOf(address(this));
            IAdapter(routes[i].adapter).swap(
                routes[i].tokenIn, routes[i].tokenOut, amtIn, address(this), routes[i].extraData
            );
            amountOut = IERC20(routes[i].tokenOut).balanceOf(address(this)) - balBefore;
        }
    }

    function _validateAdapter(address adapter) internal view {
        require(registry.isApproved(adapter), "UNAPPROVED_ADAPTER");
    }

    // ============================================================
    // Admin
    // ============================================================

    // L2: all four setters point the router at a contract it then calls unconditionally on the money
    // path — a fat-fingered address(0) would brick every swap (registry/collector) or every Permit2
    // pull, and for feeCollector it is also the address the fee is pushed to. Cheap guard, and the
    // matching checks already exist on FeeCollector's own setters.

    function setExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        executor = newExecutor;
    }

    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroAddress();
        feeCollector = IFeeCollector(newFeeCollector);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = IAdapterRegistry(newRegistry);
    }

    function setPermit2(address newPermit2) external onlyOwner {
        if (newPermit2 == address(0)) revert ZeroAddress();
        permit2 = IPermit2(newPermit2);
    }

    /// @dev Emergency: rescue stuck tokens (should never happen)
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            TransferLib.safeTransfer(token, to, balance);
        }
    }

    /// @dev Emergency: rescue stuck NATIVE MON.
    ///      L5 (2026-08-05 audit): `receive()` accepts native from anyone, and the only rescue path
    ///      (rescueTokens) reads IERC20.balanceOf, which reverts for address(0) — so a bare donation
    ///      was locked forever. The June audit closed the attached-msg.value case (_pullTokens
    ///      rejects UNEXPECTED_VALUE); this closes the donation case. Not a new attack surface: the
    ///      router never holds native between transactions on the swap path (native output is
    ///      unwrapped and forwarded to the caller in the same call).
    function rescueNative(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok, ) = payable(to).call{value: balance}("");
            if (!ok) revert NativeTransferFailed();
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

/// @dev Opt-in hook a contract-mediated caller implements to declare WHO the swap is for.
///      H2 (2026-08-05 audit): without it the router only sees the intermediary (GaslessEntry,
///      GaslessEntryPermit2, NullOrderBook, NullOneClickExecutor, NullSessionDelegate) as
///      `msg.sender`, so the self-referral guard could never fire for a contract-mediated swap and
///      an order could name its own user as referrer. Implementers return the principal for the
///      in-flight call and address(0) otherwise; the router falls back to msg.sender either way.
///      Untrusted input — used only to DROP a referral, never to move funds (see _resolveSwapper).
interface ISwapperContext {
    function currentSwapper() external view returns (address);
}
