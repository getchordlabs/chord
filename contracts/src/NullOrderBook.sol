// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";

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
/// route-shape invariants on the supplied plan. Worst-case keeper misbehaviour =
/// choosing a suboptimal route that still clears the maker's floor, or not filling.
/// (Permissionless keeping needs an oracle price bound — deliberately out of v1 scope.)
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
    event KeeperSet(address indexed keeper, bool allowed);

    error NotKeeper();
    error OrderNotFound();
    error OrderNotOpen();
    error OrderExpired();
    error FillTooEarly();
    error NotMaker();
    error InvalidParams();
    error InvalidRoutePlan();
    error BadEscrowAmount();
    error InsufficientFillOutput(uint256 received, uint256 floor);
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
            o.nextFillTime = uint64(block.timestamp) + o.interval;
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

        emit OrderFilled(orderId, o.maker, fillIndex, amountIn, received, msg.sender);
        if (completed) emit OrderCompleted(orderId);

        _send(o.tokenOut, o.maker, received);
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
