// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { INullRouter } from "./interfaces/INullRouter.sol";

/// @title NullOneClickExecutor
/// @notice Allowance-based "1-click" trading that works on EVERY wallet (MetaMask, Backpack, Phantom, …)
/// — the universal path (this is how Dirol does 1-click on non-MetaMask wallets). NOT EIP-7702/7715:
/// those are wallet-gated and break on injected MetaMask. Here a user simply:
///   (1) `approve(thisExecutor, cap)` for an input token  — the approval amount IS the spending cap, and
///   (2) `enableSession(expiry)` once,
/// after which the keeper (relayer) executes each swap with NO wallet POPUP (the FE signs the EIP-712
/// order with the wallet's existing connection) and delivers the output straight back to the user.
/// SHIPS DARK — see docs/oneclick-allowance-prompt.md.
///
/// Trust model — the keeper may only RELAY a trade the user has SIGNED:
///   * CONSENT = a user EIP-712 signature over (tokenIn, amountIn, tokenOut, minOut, routesHash, nonce,
///     deadline). Audit 2026-08-05 C1: before this, `execute` spent a standing allowance with NO user
///     signature — the keeper supplied BOTH `routes` AND `minOut`, and the validation block never checked
///     `minOut`, so `minOut = 0` + an H1 adapter route (adapters send to a caller-chosen address) drained
///     every allowance from one hot key. The digest now pins the economics AND the exact route plan, so a
///     compromised keeper can only decline to relay. Same shape as NullSessionDelegate's SessionSwap digest.
///   * CAP  = the ERC-20 allowance (auto-decrements each swap; the user approves only what they'll trade);
///   * TIME = `sessionExpiry[user]` (capped at MAX_SESSION, audit L8) + the per-order deadline;
///   * REPLAY = a per-user monotonic `nonces[user]`, bumped before the swap runs;
///   * OUTPUT ALWAYS goes back to the user (hard-coded — the keeper can never redirect funds elsewhere);
///   * ROUTER-ONLY: the executor can only `approve(router)` + call NullRouter — never an arbitrary target;
///   * REVOKE anytime: `revokeSession()` or set the allowance to 0. Non-custodial — the executor holds
///     funds only within a single tx.
///
/// Incident response (audit M7) — there was previously NO owner, NO pause and an `immutable` keeper, so
/// containment after a keeper compromise meant racing the attacker while every user revoked individually.
/// A `guardian` role now exists that can ONLY stop execution and rotate the keeper. It can never move
/// funds, never spend an allowance and never sign an order — "no owner over funds" is preserved.
contract NullOneClickExecutor {
    using SafeERC20 for IERC20;

    enum RouteKind {
        Single,
        Split,
        MultiHop
    }

    INullRouter public immutable router;
    /// @notice The only address allowed to RELAY signed swaps (the relayer). Rotatable by the guardian.
    address public keeper;
    /// @notice Can ONLY pause/unpause execution and rotate the keeper — never moves funds.
    address public guardian;
    /// @notice Guardian kill switch. While true, `execute` reverts; user grants/revokes still work.
    bool public paused;

    /// @notice Per-user session expiry (unix seconds). 0 = no active session.
    mapping(address => uint64) public sessionExpiry;
    /// @notice Per-user monotonic order nonce — the replay bound on user signatures.
    mapping(address => uint256) public nonces;

    /// @notice Documented ceiling on a session window (docs/oneclick-allowance-prompt.md:22). Previously
    /// only `expiry > block.timestamp` was checked, so `type(uint64).max` was accepted (audit L8).
    uint64 public constant MAX_SESSION = 7 days;

    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "OneClickOrder(address user,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event SessionEnabled(address indexed user, uint64 expiry);
    event SessionRevoked(address indexed user);
    event OneClickSwap(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Paused(bool paused);
    event KeeperRotated(address indexed oldKeeper, address indexed newKeeper);
    event GuardianTransferred(address indexed oldGuardian, address indexed newGuardian);

    error NotKeeper();
    error NotGuardian();
    error BadParams();
    error SessionExpired();
    error InsufficientOutput();
    error Reentrancy();
    error BadSignature();
    error BadNonce();
    error IsPaused();

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

    /// @dev The deployer becomes the initial guardian — kept as a 2-arg constructor so
    /// `script/DeployNullOneClickExecutor.s.sol` needs no change. Hand it to the Safe with
    /// `setGuardian` once the C2 multisig migration lands; the guardian can only STOP, never spend.
    constructor(address _router, address _keeper) {
        if (_router == address(0) || _keeper == address(0)) revert BadParams();
        router = INullRouter(_router);
        keeper = _keeper;
        guardian = msg.sender;
    }

    // ── guardian: STOP-only authority (never moves funds) ─────────────────────
    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @notice Halt all keeper execution instantly. Users can still revoke and pull their allowances;
    /// nothing here can move a single token.
    function setPaused(bool p) external onlyGuardian {
        paused = p;
        emit Paused(p);
    }

    /// @notice Rotate the relayer key after a compromise. A rotated-in keeper gains NO new power — it
    /// still cannot execute anything without a fresh user signature.
    function setKeeper(address newKeeper) external onlyGuardian {
        if (newKeeper == address(0)) revert BadParams();
        emit KeeperRotated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Hand the stop-authority to a new guardian (e.g. the multisig, once C2 lands).
    function setGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert BadParams();
        emit GuardianTransferred(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ── user-controlled (msg.sender = the user) ───────────────────────────────
    /// @notice Open a 1-click session until `expiry` (max MAX_SESSION out). Combined with a token
    /// approval to this executor, the keeper may then RELAY swaps you sign, up to the approved amount,
    /// until `expiry`.
    function enableSession(uint64 expiry) external {
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_SESSION) revert BadParams();
        sessionExpiry[msg.sender] = expiry;
        emit SessionEnabled(msg.sender, expiry);
    }

    /// @notice Kill your session immediately. (Setting the token allowance to 0 also stops all swaps.)
    function revokeSession() external {
        sessionExpiry[msg.sender] = 0;
        emit SessionRevoked(msg.sender);
    }

    // ── the EIP-712 order the user signs (exposed for FE/relayer parity) ──────
    function orderDigest(
        address user,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        bytes32 routesHash_,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(ORDER_TYPEHASH, user, tokenIn, amountIn, tokenOut, minOut, routesHash_, nonce, deadline)
        );
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("NullTerminal OneClick"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice The routes commitment bound into the digest — the keeper cannot swap in a different plan.
    function routesHash(INullRouter.RouteStep[] calldata routes, RouteKind kind) public pure returns (bytes32) {
        return keccak256(abi.encode(routes, kind));
    }

    // ── keeper RELAYS a user-signed swap, bounded by allowance + expiry + signature ──
    /// @param user      the trader (funds pulled from, output delivered to — never anyone else)
    /// @param routes    linear route plan from the API quote (same shape as NullRouter/NullSessionDelegate)
    /// @param userSig   the user's EIP-712 signature over `orderDigest(...)` — WITHOUT it nothing moves
    function execute(
        address user,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind,
        uint256 nonce,
        uint256 deadline,
        bytes calldata userSig
    ) external nonReentrant returns (uint256 received) {
        if (paused) revert IsPaused();
        if (msg.sender != keeper) revert NotKeeper();
        // A 0 expiry (no session / revoked) also reverts here, since block.timestamp > 0 is always true.
        if (block.timestamp > sessionExpiry[user] || block.timestamp > deadline) revert SessionExpired();
        if (
            amountIn == 0 || minOut == 0 || tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut
                || user == address(0) || routes.length == 0
        ) revert BadParams(); // minOut == 0 is never a legitimate order — it is the C1 drain shape
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != tokenIn || routes[routes.length - 1].tokenOut != tokenOut) revert BadParams();
        } else if (kind == RouteKind.Single && routes.length != 1) {
            revert BadParams();
        }
        if (nonce != nonces[user]) revert BadNonce();

        // CONSENT: every economic term AND the exact route plan are signed by the user. Recover before
        // any state change or transfer (checks-effects-interactions).
        bytes32 digest = orderDigest(
            user, tokenIn, amountIn, tokenOut, minOut, keccak256(abi.encode(routes, kind)), nonce, deadline
        );
        if (ECDSA.recover(digest, userSig) != user) revert BadSignature();
        unchecked {
            nonces[user] = nonce + 1;
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
