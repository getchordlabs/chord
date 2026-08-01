// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { INullRouter } from "./interfaces/INullRouter.sol";

/// @title NullOneClickExecutor
/// @notice Allowance-based "1-click" trading that works on EVERY wallet (MetaMask, Backpack, Phantom, …)
/// — the universal path (this is how Dirol does 1-click on non-MetaMask wallets). NOT EIP-7702/7715:
/// those are wallet-gated and break on injected MetaMask. Here a user simply:
///   (1) `approve(thisExecutor, cap)` for an input token  — the approval amount IS the spending cap, and
///   (2) `enableSession(expiry)` once,
/// after which the keeper (relayer) executes each swap with NO per-swap signature and NO popup, delivering
/// the output straight back to the user. SHIPS DARK — see docs/oneclick-allowance-prompt.md.
///
/// Trust model (the keeper may act within the user's allowance + expiry WITHOUT per-swap consent):
///   * CAP  = the ERC-20 allowance (auto-decrements each swap; the user approves only what they'll trade);
///   * TIME = `sessionExpiry[user]` — the session auto-dies; the keeper can't act past it;
///   * OUTPUT ALWAYS goes back to the user (hard-coded — the keeper can never redirect funds elsewhere);
///   * ROUTER-ONLY: the executor can only `approve(router)` + call NullRouter — never an arbitrary target;
///   * minOut enforced on-chain (+ the relayer refuses dishonest routes off-chain via an honest-minOut floor);
///   * REVOKE anytime: `revokeSession()` or set the allowance to 0. Non-custodial — the executor holds
///     funds only within a single tx.
/// Residual risk is the keeper key alone: it could force FAIR-priced swaps of approved tokens (griefing),
/// never drain them — output-to-user + minOut + the honest floor bound value extraction.
contract NullOneClickExecutor {
    using SafeERC20 for IERC20;

    enum RouteKind {
        Single,
        Split,
        MultiHop
    }

    INullRouter public immutable router;
    /// @notice The only address allowed to execute swaps on users' behalf (the relayer). Immutable.
    address public immutable keeper;

    /// @notice Per-user session expiry (unix seconds). 0 = no active session.
    mapping(address => uint64) public sessionExpiry;

    event SessionEnabled(address indexed user, uint64 expiry);
    event SessionRevoked(address indexed user);
    event OneClickSwap(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error NotKeeper();
    error BadParams();
    error SessionExpired();
    error InsufficientOutput();
    error Reentrancy();

    // Transient reentrancy guard (EIP-1153) — namespaced so it can't clash with anything.
    bytes32 private constant _REENTRANCY_SLOT = keccak256("nullterminal.oneclick.reentrancy.v1");

    modifier nonReentrant() {
        bytes32 slot = _REENTRANCY_SLOT;
        assembly {
            if tload(slot) { revert(0, 0) }
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    constructor(address _router, address _keeper) {
        if (_router == address(0) || _keeper == address(0)) revert BadParams();
        router = INullRouter(_router);
        keeper = _keeper;
    }

    // ── user-controlled (msg.sender = the user) ───────────────────────────────
    /// @notice Open a 1-click session until `expiry`. Combined with a token approval to this executor,
    /// the keeper may then swap that token on your behalf up to the approved amount, until `expiry`.
    function enableSession(uint64 expiry) external {
        if (expiry <= block.timestamp) revert BadParams();
        sessionExpiry[msg.sender] = expiry;
        emit SessionEnabled(msg.sender, expiry);
    }

    /// @notice Kill your session immediately. (Setting the token allowance to 0 also stops all swaps.)
    function revokeSession() external {
        sessionExpiry[msg.sender] = 0;
        emit SessionRevoked(msg.sender);
    }

    // ── keeper executes a swap on the user's behalf, bounded by allowance + expiry ──
    /// @param user      the trader (funds pulled from, output delivered to — never anyone else)
    /// @param routes    linear route plan from the API quote (same shape as NullRouter/NullSessionDelegate)
    function execute(
        address user,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (msg.sender != keeper) revert NotKeeper();
        // A 0 expiry (no session / revoked) also reverts here, since block.timestamp > 0 is always true.
        if (block.timestamp > sessionExpiry[user] || block.timestamp > deadline) revert SessionExpired();
        if (
            amountIn == 0 || tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut
                || user == address(0) || routes.length == 0
        ) revert BadParams();
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != tokenIn || routes[routes.length - 1].tokenOut != tokenOut) revert BadParams();
        } else if (kind == RouteKind.Single && routes.length != 1) {
            revert BadParams();
        }

        // Pull the user's tokens — bounded by their allowance to this executor (= the spending cap).
        IERC20(tokenIn).safeTransferFrom(user, address(this), amountIn);
        received = _routeSwap(tokenIn, tokenOut, amountIn, minOut, routes, kind);
        IERC20(tokenOut).safeTransfer(user, received); // output ALWAYS to the user
        emit OneClickSwap(user, tokenIn, tokenOut, amountIn, received);
    }

    /// @dev ROUTER-ONLY: approve exact + swap; output lands on this executor (msg.sender). Split into a
    /// helper so `execute` stays under the stack limit. Enforces minOut here.
    function _routeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind
    ) private returns (uint256 received) {
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        if (kind == RouteKind.Single) {
            router.swap(tokenIn, tokenOut, amountIn, minOut, block.timestamp, routes[0], address(0));
        } else if (kind == RouteKind.Split) {
            router.splitSwap(tokenIn, tokenOut, amountIn, minOut, block.timestamp, routes, address(0));
        } else {
            router.multiHopSwap(amountIn, minOut, block.timestamp, routes, address(0));
        }
        IERC20(tokenIn).forceApprove(address(router), 0);
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received < minOut) revert InsufficientOutput();
    }
}
