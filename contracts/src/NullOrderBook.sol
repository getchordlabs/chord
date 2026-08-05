// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";

/// @dev Reference-price source for the keeper sanity bound (audit 2026-08-05, H3).
///      `referenceOut` must answer "what should `amountIn` of tokenIn be worth in tokenOut right
///      now", using the SAME address(0)=native-MON convention the order book uses.
///
///      TRUST ASSUMPTION: this must be a manipulation-resistant source (TWAP / multi-venue
///      aggregate), NOT a spot quote off the pools the keeper is allowed to route through — a spot
///      source can be moved inside the very transaction it is meant to police. The order book
///      cannot verify that property; the owner takes it on when calling `setOracle`.
interface IOrderBookOracle {
    function referenceOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 refOut);
}

/// @dev Overload surface of NullRouter not present in INullRouter (native-out multi-hop).
interface INullRouterMultiHopNative {
    function multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        INullRouter.RouteStep[] calldata routes,
        address referrer,
        bool unwrapOutput
    ) external payable returns (uint256 amountOut);
}

/// @title NullOrderBook
/// @notice Escrowed limit orders + DCA schedules executed through the audited NullRouter.
///
/// A LIMIT order is a DCA order with numFills = 1, interval = 0. Makers escrow
/// `amountPerFill * numFills` of tokenIn at creation and can cancel (refunding all
/// unfilled fills) at any time — including after expiry.
///
/// Execution model (v1): whitelisted keepers watch the routing engine and call
/// `executeFill` with ONLY a route plan. Every economically meaningful parameter —
/// token pair, fill amount, minimum output, referrer — is read from ORDER STATE, never
/// from keeper input, so a malicious/compromised keeper cannot redirect funds or relax
/// the maker's price floor. The router additionally enforces its adapter whitelist and
/// route-shape invariants on the supplied plan.
///
/// KEEPER SURPLUS BOUND (audit 2026-08-05, H3). The earlier claim here — "worst-case keeper
/// misbehaviour = a suboptimal route that still clears the floor" — was wrong. A keeper that
/// controls a pool an approved adapter will trade against can realise EXACTLY the floor
/// deterministically (sell the maker's input at market inside the same call, hand back precisely
/// `minOutPerFill`, pocket the rest) and emit an `OrderFilled` indistinguishable from an honest
/// fill. On the shipped 5% DCA default that is a guaranteed ~5% skim; on a limit order that gapped
/// through its trigger it is unbounded. Two mitigations, both here, neither sufficient alone:
///   1. `oracle` + `maxDeviationBps` — a reference-price bound on the measured `received`, so the
///      maker's floor is no longer the ONLY protection. Skipped entirely when unset (see
///      `setOracle`), so an unconfigured book behaves exactly as before.
///   2. `maxFillDelay` — caps how long a keeper may sit on a DUE **DCA** slot, shrinking the
///      free option of waiting for a dip that still clears the floor. Limit orders are exempt:
///      "fill whenever price crosses" IS the product, so their only bound is (1).
/// The structural fix is adapter-side pool provenance (audit H1); these are the containment that
/// does not require redeploying every adapter.
///
/// Fund-safety invariants:
/// - tokenIn approval to the router is granted for EXACTLY one fill and revoked in the
///   same transaction; the contract never holds a standing approval.
/// - Output is measured by balance delta and checked against the maker's floor even
///   though the router already enforces minAmountOut (belt-and-suspenders vs a future
///   router upgrade bug).
/// - Fee-on-transfer tokens are rejected at escrow (delta != expected reverts).
/// - address(0) = native MON on either side (never both). Native out uses the router's
///   sentinel/unwrap paths; receive() only accepts MON from the router.
contract NullOrderBook is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    // Types
    // ============================================================

    enum RouteKind {
        Single, // router.swap
        Split, // router.splitSwap
        MultiHop // router.multiHopSwap
    }

    struct Order {
        address maker; // slot 0
        uint64 expiry; // no fills after this timestamp (cancel/refund always works)
        uint32 numFills; // 1 = limit order
        address tokenIn; // slot 1 — address(0) = native MON
        uint64 interval; // seconds between fills (0 for limit orders)
        uint32 filledCount;
        address tokenOut; // slot 2 — address(0) = native MON
        uint64 nextFillTime; // earliest timestamp the next fill may execute
        bool cancelled;
        uint128 amountPerFill; // slot 3
        uint128 minOutPerFill; // maker's price floor per fill (> 0 enforced)
        address referrer; // slot 4 — forwarded to the router's referral split
    }

    // ============================================================
    // Storage
    // ============================================================

    INullRouter public immutable router;
    address public immutable wmon;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;

    /// @notice Open (fillable) order ids — O(1) removal via swap-remove.
    uint256[] private _openIds;
    mapping(uint256 => uint256) private _openIndex; // orderId → index+1 (0 = not open)

    /// @notice All order ids ever created by a maker (FE filters by status).
    mapping(address => uint256[]) private _makerOrders;

    mapping(address => bool) public isKeeper;

    // ---- H3 / M8 additions (audit 2026-08-05). Plain contract, not a proxy — but appended
    //      anyway so a future upgrade-to-proxy inherits a clean layout. ----

    uint256 private constant BPS = 10_000;

    /// @notice Reference-price source for the keeper surplus bound. address(0) = disabled.
    IOrderBookOracle public oracle;

    /// @notice How far BELOW the oracle reference a fill may land before it is rejected.
    ///         0 = disabled (also the state when `oracle` is unset).
    uint16 public maxDeviationBps;

    /// @notice Seconds a keeper may sit on a DUE DCA slot before that slot's window closes and the
    ///         schedule rolls to the next one. 0 = unbounded (pre-audit behaviour).
    uint64 public maxFillDelay;

    /// @notice Upper bound on `expiry - now` at creation. Bounds how long an un-fillable spam order
    ///         can squat in `_openIds` before `pruneExpired` can evict it. 0 = unbounded.
    uint64 public maxOrderTtl;

    /// @notice Per-tokenIn minimum `amountPerFill` (anti dust-spam). 0 = no minimum for that token.
    mapping(address => uint128) public minAmountPerFill;

    // ============================================================
    // Events / Errors
    // ============================================================

    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint128 amountPerFill,
        uint128 minOutPerFill,
        uint32 numFills,
        uint64 interval,
        uint64 expiry,
        address referrer
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed maker,
        uint32 fillIndex,
        uint256 amountIn,
        uint256 amountOut,
        address keeper
    );
    event OrderCompleted(uint256 indexed orderId);
    event OrderCancelled(uint256 indexed orderId, uint256 refunded);
    event OrderPruned(uint256 indexed orderId);
    event KeeperSet(address indexed keeper, bool allowed);
    event OracleSet(address indexed oracle, uint16 maxDeviationBps);
    event MaxFillDelaySet(uint64 maxFillDelay);
    event MaxOrderTtlSet(uint64 maxOrderTtl);
    event MinAmountPerFillSet(address indexed token, uint128 minAmount);

    error NotKeeper();
    error OrderNotFound();
    error OrderNotOpen();
    error OrderExpired();
    error FillTooEarly();
    error FillWindowMissed(uint256 lateBy, uint64 maxFillDelay);
    error NotMaker();
    error InvalidParams();
    error InvalidRoutePlan();
    error BadEscrowAmount();
    error InsufficientFillOutput(uint256 received, uint256 floor);
    error OracleBoundViolated(uint256 received, uint256 oracleFloor);
    error OracleUnavailable();
    error BelowMinNotional(uint128 amountPerFill, uint128 required);
    error ExpiryTooFar(uint64 expiry, uint64 maxExpiry);
    error NativeTransferFailed();
    error UnexpectedNative();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address router_, address wmon_, address owner_) Ownable(owner_) {
        if (router_ == address(0) || wmon_ == address(0)) revert InvalidParams();
        router = INullRouter(router_);
        wmon = wmon_;
        // Safe-by-default rather than off-by-default: a book deployed and forgotten still bounds
        // keeper timing discretion and still produces prunable orders. Both are owner-tunable.
        maxFillDelay = 15 minutes;
        maxOrderTtl = 365 days;
        // `oracle` stays unset: there is no reference source to point at yet, and a wrong one is
        // worse than none (it would gate every fill on a number nobody validated).
    }

    // ============================================================
    // Maker actions
    // ============================================================

    /// @notice Create a limit order (numFills = 1) or DCA schedule (numFills > 1).
    /// @dev Escrows amountPerFill * numFills of tokenIn. For native MON the full escrow
    ///      must be attached as msg.value; for ERC20 it is pulled (FOT tokens rejected).
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint128 amountPerFill,
        uint128 minOutPerFill,
        uint32 numFills,
        uint64 interval,
        uint64 expiry,
        address referrer
    ) external payable nonReentrant returns (uint256 orderId) {
        if (amountPerFill == 0 || numFills == 0) revert InvalidParams();
        // minOut floor is mandatory: a zero floor would let ANY fill price through —
        // the FE derives "market" DCA floors from spot minus max slippage instead.
        if (minOutPerFill == 0) revert InvalidParams();
        if (tokenIn == tokenOut) revert InvalidParams();
        // MON↔WMON is a wrap/unwrap, not a swap — the router can't route it.
        if (
            (tokenIn == address(0) && tokenOut == wmon) ||
            (tokenIn == wmon && tokenOut == address(0))
        ) revert InvalidParams();
        if (expiry <= block.timestamp) revert InvalidParams();
        if (numFills > 1 && interval == 0) revert InvalidParams();

        // M8 anti-spam. createOrder is permissionless and pushes into `_openIds` unconditionally,
        // so junk orders are a DoS on the OFF-CHAIN keeper (10k dust orders → openOrderIds()
        // outgrows an RPC response). Two cheap bounds, both owner-tunable, both no-ops when unset:
        //   - a per-token minimum size, so spam costs real capital in a token we actually route;
        //   - a TTL, so every order eventually becomes evictable by `pruneExpired` (without it a
        //     spammer just sets expiry = type(uint64).max and squats forever).
        uint128 minFill = minAmountPerFill[tokenIn];
        if (minFill != 0 && amountPerFill < minFill) revert BelowMinNotional(amountPerFill, minFill);
        if (maxOrderTtl != 0) {
            uint256 maxExpiry = block.timestamp + maxOrderTtl;
            if (expiry > maxExpiry) revert ExpiryTooFar(expiry, uint64(maxExpiry));
        }

        uint256 totalEscrow = uint256(amountPerFill) * numFills;

        if (tokenIn == address(0)) {
            if (msg.value != totalEscrow) revert BadEscrowAmount();
        } else {
            if (msg.value != 0) revert UnexpectedNative();
            uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalEscrow);
            // Reject fee-on-transfer tokens — escrow accounting requires exact receipt.
            if (IERC20(tokenIn).balanceOf(address(this)) - balBefore != totalEscrow) {
                revert BadEscrowAmount();
            }
        }

        orderId = nextOrderId++;
        orders[orderId] = Order({
            maker: msg.sender,
            expiry: expiry,
            numFills: numFills,
            tokenIn: tokenIn,
            interval: interval,
            filledCount: 0,
            tokenOut: tokenOut,
            nextFillTime: uint64(block.timestamp), // first fill allowed immediately
            cancelled: false,
            amountPerFill: amountPerFill,
            minOutPerFill: minOutPerFill,
            referrer: referrer == msg.sender ? address(0) : referrer
        });

        _openIds.push(orderId);
        _openIndex[orderId] = _openIds.length; // index+1
        _makerOrders[msg.sender].push(orderId);

        emit OrderCreated(
            orderId,
            msg.sender,
            tokenIn,
            tokenOut,
            amountPerFill,
            minOutPerFill,
            numFills,
            interval,
            expiry,
            referrer
        );
    }

    /// @notice Cancel an order and refund all unfilled fills. Works before AND after
    ///         expiry — maker funds are never stranded.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound();
        if (o.maker != msg.sender) revert NotMaker();
        if (o.cancelled || o.filledCount == o.numFills) revert OrderNotOpen();

        o.cancelled = true;
        _removeOpen(orderId);

        uint256 refund = uint256(o.amountPerFill) * (o.numFills - o.filledCount);
        emit OrderCancelled(orderId, refund);
        _send(o.tokenIn, o.maker, refund);
    }

    // ============================================================
    // Keeper execution
    // ============================================================

    /// @notice Execute one fill of an order through the NullRouter.
    /// @param orderId  The order to fill.
    /// @param routes   Route plan from the routing engine. Single: length 1. Split:
    ///                 legs of the same pair summing to amountPerFill. MultiHop: ordered
    ///                 hops. The router re-validates shape + adapter whitelist.
    /// @param kind     Which router entrypoint the plan targets.
    function executeFill(
        uint256 orderId,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind
    ) external onlyKeeper nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound();
        if (o.cancelled || o.filledCount >= o.numFills) revert OrderNotOpen();
        if (block.timestamp > o.expiry) revert OrderExpired();
        if (block.timestamp < o.nextFillTime) revert FillTooEarly();
        if (routes.length == 0) revert InvalidRoutePlan();

        // H3 (timing half): a DCA slot is fillable for `maxFillDelay` seconds and then closes —
        // the keeper cannot hold a due slot open across the whole interval waiting for a dip that
        // still clears the floor. The window REOPENS every interval (`% o.interval`), so a missed
        // slot self-heals at the next boundary instead of bricking the order. Limit orders
        // (interval == 0) are exempt by construction: filling whenever price crosses IS the
        // product; their bound is the oracle check below.
        uint64 window = maxFillDelay;
        if (window != 0 && o.interval != 0) {
            uint256 lateBy = (block.timestamp - o.nextFillTime) % o.interval;
            if (lateBy > window) revert FillWindowMissed(lateBy, window);
        }

        bool nativeIn = o.tokenIn == address(0);
        bool nativeOut = o.tokenOut == address(0);
        uint256 amountIn = o.amountPerFill;
        // Router native-in convention (mirrors the API txBuilder): tokenIn/route legs
        // say WMON while msg.value carries the MON — _pullTokens wraps it.
        address routerTokenIn = nativeIn ? wmon : o.tokenIn;

        // MultiHop entry/exit tokens are derived from the plan by the router — pin them
        // to the order here. (Single/Split are pinned by the typed args below.)
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != routerTokenIn) revert InvalidRoutePlan();
            address lastOut = routes[routes.length - 1].tokenOut;
            if (nativeOut ? lastOut != wmon : lastOut != o.tokenOut) revert InvalidRoutePlan();
        }

        // Effects BEFORE the external call (nonReentrant is the backstop; keep CEI shape).
        uint32 fillIndex = o.filledCount;
        o.filledCount = fillIndex + 1;
        bool completed = o.filledCount == o.numFills;
        if (completed) {
            _removeOpen(orderId);
        } else {
            // Anchor the next slot to the one we just SERVED, not to when the fill landed —
            // anchoring on `block.timestamp` made every late fill shift the whole schedule, so
            // lateness compounded across a DCA (audit 2026-08-05, informational). Clamp forward so
            // a fill that lands several intervals late does not leave a burst of due back-slots.
            uint256 next = uint256(o.nextFillTime) + o.interval;
            if (next < block.timestamp) next = block.timestamp;
            o.nextFillTime = uint64(next);
        }

        // Interaction: scoped exact approval → router call → revoke.
        uint256 outBefore = _balanceOf(o.tokenOut);
        uint256 msgValue = 0;
        if (nativeIn) {
            msgValue = amountIn;
        } else {
            IERC20(o.tokenIn).forceApprove(address(router), amountIn);
        }

        if (kind == RouteKind.Single) {
            if (routes.length != 1) revert InvalidRoutePlan();
            router.swap{value: msgValue}(
                routerTokenIn, o.tokenOut, amountIn, o.minOutPerFill, block.timestamp, routes[0], o.referrer
            );
        } else if (kind == RouteKind.Split) {
            router.splitSwap{value: msgValue}(
                routerTokenIn, o.tokenOut, amountIn, o.minOutPerFill, block.timestamp, routes, o.referrer
            );
        } else if (nativeOut) {
            // 6-arg overload (unwrapOutput) — requires the dff96f8+ router build.
            INullRouterMultiHopNative(address(router)).multiHopSwap{value: msgValue}(
                amountIn, o.minOutPerFill, block.timestamp, routes, o.referrer, true
            );
        } else {
            // Canonical 5-arg multiHopSwap — present on the currently deployed router,
            // so ERC20-out multi-hop fills work without waiting for the upgrade.
            router.multiHopSwap{value: msgValue}(
                amountIn, o.minOutPerFill, block.timestamp, routes, o.referrer
            );
        }

        if (!nativeIn) {
            IERC20(o.tokenIn).forceApprove(address(router), 0);
        }

        // Belt-and-suspenders: verify the delta we actually received clears the floor,
        // independent of the router's own minAmountOut check.
        uint256 received = _balanceOf(o.tokenOut) - outBefore;
        if (received < o.minOutPerFill) revert InsufficientFillOutput(received, o.minOutPerFill);

        // H3 (price half): the maker's floor is not the only protection. A keeper that can realise
        // EXACTLY `minOutPerFill` through a pool it controls now also has to land within
        // `maxDeviationBps` of an independent reference, which caps the skim at that deviation
        // instead of at the full distance between floor and market.
        uint256 oracleFloor = _oracleFloor(o.tokenIn, o.tokenOut, amountIn);
        if (received < oracleFloor) revert OracleBoundViolated(received, oracleFloor);

        emit OrderFilled(orderId, o.maker, fillIndex, amountIn, received, msg.sender);
        if (completed) emit OrderCompleted(orderId);

        _send(o.tokenOut, o.maker, received);
    }

    // ============================================================
    // Keeper hygiene
    // ============================================================

    /// @notice Evict ids from the open list that can never be filled again — permissionless.
    /// @dev M8: `_openIds` only ever shrank on maker-cancel or completion, so an expired order (or
    ///      a wave of dust spam) sat in the keeper's work list forever. This removes ONLY ids that
    ///      are genuinely dead: expired, cancelled, or fully filled. It touches no balances and
    ///      does NOT close the order — `cancelOrder` still refunds the maker afterwards, because
    ///      cancellation never depended on open-list membership (and `_removeOpen` no-ops on an
    ///      id already pruned). Ineligible ids are skipped rather than reverting, so one live id
    ///      in a batch cannot grief the whole prune.
    /// @param ids Candidate order ids (the keeper reads them from `openOrderIds()`).
    /// @return pruned How many ids were actually removed.
    function pruneExpired(uint256[] calldata ids) external returns (uint256 pruned) {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (_openIndex[id] == 0) continue; // unknown or already pruned/closed
            Order storage o = orders[id];
            bool dead = o.cancelled || o.filledCount >= o.numFills || block.timestamp > o.expiry;
            if (!dead) continue;
            _removeOpen(id);
            unchecked {
                ++pruned;
            }
            emit OrderPruned(id);
        }
    }

    // ============================================================
    // Views
    // ============================================================

    /// @notice All currently open (fillable or waiting) order ids — keeper work list.
    function openOrderIds() external view returns (uint256[] memory) {
        return _openIds;
    }

    function openOrderCount() external view returns (uint256) {
        return _openIds.length;
    }

    /// @notice Every order id a maker has created (open + closed).
    function ordersOf(address maker) external view returns (uint256[] memory) {
        return _makerOrders[maker];
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    // ============================================================
    // Admin
    // ============================================================

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert InvalidParams();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Configure the reference-price bound on fills (H3).
    /// @dev Degrades to exactly the pre-audit behaviour when disabled: pass `oracle_ = address(0)`
    ///      (or `maxDeviationBps_ = 0`) and `_oracleFloor` returns 0, so only the maker's floor
    ///      applies. Enabling it is a LIVENESS tradeoff the owner is making knowingly: a
    ///      configured oracle that reverts or answers 0 fails CLOSED (`OracleUnavailable`), because
    ///      falling back to the floor on error would hand the keeper the exact bypass this bound
    ///      exists to remove. Restore liveness by clearing the oracle, not by weakening the check.
    ///      See `IOrderBookOracle` for the manipulation-resistance assumption on `oracle_`.
    /// @param oracle_          Reference source, or address(0) to disable the bound entirely.
    /// @param maxDeviationBps_ Allowed shortfall vs the reference, in bps (capped at 50%).
    function setOracle(address oracle_, uint16 maxDeviationBps_) external onlyOwner {
        if (maxDeviationBps_ > BPS / 2) revert InvalidParams();
        if (oracle_ != address(0) && maxDeviationBps_ == 0) revert InvalidParams();
        oracle = IOrderBookOracle(oracle_);
        maxDeviationBps = maxDeviationBps_;
        emit OracleSet(oracle_, maxDeviationBps_);
    }

    /// @notice Seconds a keeper may sit on a due DCA slot. 0 = unbounded (pre-audit behaviour).
    function setMaxFillDelay(uint64 maxFillDelay_) external onlyOwner {
        maxFillDelay = maxFillDelay_;
        emit MaxFillDelaySet(maxFillDelay_);
    }

    /// @notice Cap on order lifetime at creation, so every order eventually becomes prunable (M8).
    function setMaxOrderTtl(uint64 maxOrderTtl_) external onlyOwner {
        maxOrderTtl = maxOrderTtl_;
        emit MaxOrderTtlSet(maxOrderTtl_);
    }

    /// @notice Per-token minimum `amountPerFill`. 0 = no minimum (default) (M8).
    function setMinAmountPerFill(address token, uint128 minAmount) external onlyOwner {
        minAmountPerFill[token] = minAmount;
        emit MinAmountPerFillSet(token, minAmount);
    }

    // ============================================================
    // Internal
    // ============================================================

    function _removeOpen(uint256 orderId) internal {
        uint256 idxPlus = _openIndex[orderId];
        if (idxPlus == 0) return;
        uint256 idx = idxPlus - 1;
        uint256 lastId = _openIds[_openIds.length - 1];
        _openIds[idx] = lastId;
        _openIndex[lastId] = idx + 1;
        _openIds.pop();
        delete _openIndex[orderId];
    }

    /// @dev Minimum output this fill must produce per the reference source, or 0 when the bound is
    ///      disabled. Tokens are passed with the order book's address(0)=native-MON convention.
    function _oracleFloor(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        IOrderBookOracle o_ = oracle;
        uint16 devBps = maxDeviationBps;
        if (address(o_) == address(0) || devBps == 0) return 0;

        uint256 ref;
        try o_.referenceOut(tokenIn, tokenOut, amountIn) returns (uint256 r) {
            ref = r;
        } catch {
            revert OracleUnavailable(); // fail closed — see setOracle
        }
        if (ref == 0) revert OracleUnavailable();
        return (ref * (BPS - devBps)) / BPS;
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Native MON only ever arrives from the router (native-out settlement).
    ///      Maker escrow arrives via createOrder's msg.value, not here.
    receive() external payable {
        if (msg.sender != address(router)) revert UnexpectedNative();
    }
}
