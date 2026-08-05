// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { INullRouter } from "./interfaces/INullRouter.sol";

/// @title NullSessionDelegate
/// @notice EIP-7702 delegate for zero-popup "session" trading on Monad. A user delegates their EOA to
/// this contract and grants a short-lived session ONCE; afterwards each swap needs NO wallet popup and
/// NO user gas. SHIPS DARK — see docs/session-trading-v2-prompt.md + docs/session-trading-risk.md.
///
/// Security model — DUAL SIGNATURE (this is the whole point):
///   Every `executeSession` requires BOTH
///     (a) the session key's signature (the FE holds it in memory, signs without a wallet popup), and
///     (b) a whitelisted relayer's co-signature over the SAME swap digest.
///   The relayer only co-signs routes it computed with an honest minOut, so a leaked session key ALONE
///   is useless (the relayer will not co-sign a malicious route), and a compromised relayer alone is
///   useless (no valid session grant). Both must be compromised to act — and even then the loss is
///   bounded by the per-token spend cap.
///
/// Hard limits enforced on-chain:
///   * grant/revoke are callable ONLY by the EOA itself (`msg.sender == address(this)`, a 7702 self-call);
///   * per-token cumulative spend cap (cap == 0 means the token is not allow-listed);
///   * session expiry + a per-swap deadline;
///   * monotonic session nonce (replay-safe);
///   * ROUTER-ONLY: the delegate can only `approve(router)` + `router.swap(...)` with the output
///     delivered to the EOA itself — it can never transfer tokens elsewhere or call another contract.
///
/// State lives in the EOA's storage under a namespaced (ERC-7201) slot so a later re-delegation to a
/// different contract cannot silently reuse it.
///
/// ⚠️ CLEARING A DELEGATION IS NOT A REVOCATION (audit 2026-08-05 M4). `revokeSession` needs a 7702
/// self-call, which only works while this delegate is still installed. Setting the account's code back
/// to `0x` leaves `granted`/`sessionKey`/`expiry`/`epoch`/caps written in the EOA's storage — storage
/// survives code removal — so re-delegating to this same contract would resurrect the grant. Two things
/// close that: (a) execution is gated on a `granted` flag that ONLY `grantSession` can set, so storage
/// left behind by any other delegate fails closed; and (b) `revokeForever()` is a PLAIN transaction sent
/// to the DEPLOYED delegate address (`SELF`) — it needs no delegation installed, records the kill in the
/// DEPLOYED contract's own storage (not the EOA's), and is therefore immune to code clearing and to
/// re-delegation. The FE must tell users to call `revokeForever()` before clearing their delegation.
contract NullSessionDelegate {
    using SafeERC20 for IERC20;

    enum RouteKind {
        Single,
        Split,
        MultiHop
    }

    // ── namespaced storage (ERC-7201) ────────────────────────────────────────
    /// @custom:storage-location erc7201:nullterminal.session.v1
    struct SessionStorage {
        address sessionKey;
        uint64 expiry;
        uint64 nonce;
        // Bumped on every grant/revoke → the current session's caps + allow-list live under this epoch,
        // so a re-grant or revoke instantly invalidates ALL prior caps with no stale carry-over (F-2).
        uint64 epoch;
        mapping(uint256 => mapping(address => uint256)) capByEpoch; // epoch => token => remaining spend cap
        mapping(uint256 => mapping(address => bool)) allowedByEpoch; // epoch => token => allow-listed (as in OR out)
        // APPEND ONLY BELOW — this struct is laid out in the USER'S EOA storage, which survives both
        // code clearing and re-delegation. Inserting a field above would re-interpret live grants.
        // M4: set ONLY by grantSession, cleared by revokeSession. Storage written by a *different*
        // delegate at this same ERC-7201 slot can never satisfy it, so execution fails closed.
        bool granted;
    }
    // keccak256(abi.encode(uint256(keccak256("nullterminal.session.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SESSION_SLOT = 0xcfac13c1098f5578e7cd69e27b116684fce86d87a76fda0b94b5180cbeceb500;

    function _s() private pure returns (SessionStorage storage s) {
        assembly {
            s.slot := SESSION_SLOT
        }
    }

    // Transient reentrancy guard (EIP-1153) — defense in depth on top of checks-effects-interactions.
    // Namespaced transient slot so it can't clash with the persistent session storage.
    bytes32 private constant _REENTRANCY_SLOT = keccak256("nullterminal.session.reentrancy.v1");

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

    // ── config (immutable — a single trusted relayer for the MVP) ─────────────
    INullRouter public immutable router;
    address public immutable relayer;
    address public immutable wmon;
    /// @notice The DEPLOYED delegate address. Under 7702 `address(this)` is the EOA, so this is the only
    /// way back to the contract's OWN storage — where the delegation-independent kill switch lives (M4).
    address public immutable SELF;

    /// @dev Lives in the DEPLOYED contract's storage ONLY (writes are gated on `address(this) == SELF`),
    /// so it survives a user clearing their 7702 delegation and any later re-delegation.
    mapping(address => bool) private _revokedForever;

    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "SessionSwap(address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event SessionGranted(address indexed eoa, address indexed sessionKey, uint64 expiry);
    event SessionRevoked(address indexed eoa);
    event SessionRevokedForever(address indexed eoa);
    event SessionSwap(
        address indexed eoa,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 received,
        uint64 nonce
    );

    error OnlySelf();
    error BadParams();
    error SessionExpired();
    error BadNonce();
    error CapExceeded();
    error TokenNotAllowed();
    error BadSessionSig();
    error BadRelayerSig();
    error InvalidRoutePlan();
    error InsufficientOutput();
    error SessionNotGranted();
    error SessionKilled();
    error OnlyDeployedDelegate();

    constructor(address router_, address relayer_, address wmon_) {
        if (router_ == address(0) || relayer_ == address(0) || wmon_ == address(0)) revert BadParams();
        router = INullRouter(router_);
        relayer = relayer_;
        wmon = wmon_;
        SELF = address(this);
    }

    // ── grant / revoke — only the EOA itself (7702 self-call) ─────────────────
    function grantSession(address sessionKey, uint64 expiry, address[] calldata tokens, uint256[] calldata caps)
        external
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (sessionKey == address(0) || expiry <= block.timestamp || tokens.length != caps.length) revert BadParams();
        SessionStorage storage s = _s();
        // Fresh epoch → every prior cap + allow-list entry is instantly invalidated (F-2: no stale carry-over).
        uint64 epoch = s.epoch + 1;
        s.epoch = epoch;
        s.sessionKey = sessionKey;
        s.expiry = expiry;
        // NOTE: nonce is NOT reset — it stays monotonic across grants. Resetting it would let a
        // previously-signed-but-unused message be replayed if the same session key is ever re-granted.
        s.granted = true; // M4: the ONLY writer of this flag
        for (uint256 i = 0; i < tokens.length;) {
            s.capByEpoch[epoch][tokens[i]] = caps[i];
            s.allowedByEpoch[epoch][tokens[i]] = true; // allow-listed as an input AND an output token
            unchecked {
                ++i;
            }
        }
        emit SessionGranted(address(this), sessionKey, expiry);
    }

    function revokeSession() external {
        if (msg.sender != address(this)) revert OnlySelf();
        SessionStorage storage s = _s();
        s.epoch += 1; // invalidate the current session's caps + allow-list in one write
        s.sessionKey = address(0);
        s.expiry = 0;
        s.granted = false;
        emit SessionRevoked(address(this));
    }

    /// @notice Permanently kill every session for the calling account — INDEPENDENT of the delegation.
    /// @dev M4. This is a PLAIN transaction sent to the deployed delegate (`SELF`), so it works when the
    /// account has no code at all: the natural "clear my delegation" flow leaves the grant sitting in the
    /// EOA's storage, and re-delegating would otherwise resurrect it. The kill is recorded here, in the
    /// deployed contract's storage, which no re-delegation can touch. Deliberately one-way: `grantSession`
    /// cannot clear it, so a compromised session key can never un-kill an account. Re-enabling requires a
    /// new delegate deployment (the same act of trust as the first grant).
    function revokeForever() external {
        if (address(this) != SELF) revert OnlyDeployedDelegate(); // a delegated call would write EOA storage
        _revokedForever[msg.sender] = true;
        emit SessionRevokedForever(msg.sender);
    }

    /// @notice Whether `eoa` has permanently killed session trading (read cross-context via `SELF`).
    function isRevokedForever(address eoa) external view returns (bool) {
        return _revokedForever[eoa];
    }

    // ── views (FE reads remaining cap / expiry / nonce) ───────────────────────
    function sessionInfo() external view returns (address sessionKey, uint64 expiry, uint64 nonce) {
        SessionStorage storage s = _s();
        return (s.sessionKey, s.expiry, s.nonce);
    }

    function remainingCap(address token) external view returns (uint256) {
        SessionStorage storage s = _s();
        return s.capByEpoch[s.epoch][token];
    }

    function isAllowed(address token) external view returns (bool) {
        SessionStorage storage s = _s();
        return s.allowedByEpoch[s.epoch][token];
    }

    // ── execute a session swap (dual-sig, no user popup, relayer pays gas) ─────
    function executeSession(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sessionSig,
        bytes calldata relayerSig
    ) external nonReentrant {
        SessionStorage storage s = _s();
        // M4: a grant this delegate itself made, and not killed out-of-band. `granted` fails closed on
        // storage left by another delegate; `isRevokedForever` survives clear-then-re-delegate because it
        // lives in the DEPLOYED contract's storage, not the EOA's.
        if (!s.granted) revert SessionNotGranted();
        if (NullSessionDelegate(payable(SELF)).isRevokedForever(address(this))) revert SessionKilled();
        if (block.timestamp > deadline || block.timestamp > s.expiry) revert SessionExpired();
        if (nonce != s.nonce) revert BadNonce();
        // v1 is ERC20-in → ERC20-out only (allow-list is ERC20 majors) — no native-out edge paths.
        if (amountIn == 0 || tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || routes.length == 0) {
            revert InvalidRoutePlan();
        }

        // Digest binds every economic term + the exact route; BOTH parties sign it.
        bytes32 digest =
            _digest(tokenIn, amountIn, tokenOut, minOut, keccak256(abi.encode(routes, kind)), nonce, deadline);
        if (ECDSA.recover(digest, sessionSig) != s.sessionKey || s.sessionKey == address(0)) revert BadSessionSig();
        if (ECDSA.recover(digest, relayerSig) != relayer) revert BadRelayerSig();

        // BOTH sides must be allow-listed. tokenIn also needs remaining cap; tokenOut being allow-listed
        // (a trusted major) is what stops even a DUAL-compromised session from routing the capped input
        // into an attacker honeypot (audit F-1). The cap is the cash bound; the allow-list bounds WHERE.
        uint64 epoch = s.epoch;
        if (!s.allowedByEpoch[epoch][tokenOut]) revert TokenNotAllowed();
        uint256 cap = s.capByEpoch[epoch][tokenIn];
        if (!s.allowedByEpoch[epoch][tokenIn] || cap < amountIn) revert CapExceeded();
        unchecked {
            s.capByEpoch[epoch][tokenIn] = cap - amountIn;
            s.nonce = s.nonce + 1;
        }

        // ROUTER-ONLY: approve exact + swap; output is delivered to the EOA (address(this)), and both
        // tokens are allow-listed majors, so a session can only ever move value between trusted tokens
        // held by the user — bounded by the per-token cap.
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != tokenIn || routes[routes.length - 1].tokenOut != tokenOut) revert InvalidRoutePlan();
        }

        uint256 outBefore = _balanceOf(tokenOut);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        if (kind == RouteKind.Single) {
            if (routes.length != 1) revert InvalidRoutePlan();
            router.swap(tokenIn, tokenOut, amountIn, minOut, block.timestamp, routes[0], address(0));
        } else if (kind == RouteKind.Split) {
            router.splitSwap(tokenIn, tokenOut, amountIn, minOut, block.timestamp, routes, address(0));
        } else {
            router.multiHopSwap(amountIn, minOut, block.timestamp, routes, address(0));
        }
        IERC20(tokenIn).forceApprove(address(router), 0);

        uint256 received = _balanceOf(tokenOut) - outBefore;
        if (received < minOut) revert InsufficientOutput();
        emit SessionSwap(address(this), tokenIn, tokenOut, amountIn, received, uint64(nonce));
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _digest(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        bytes32 routesHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(SWAP_TYPEHASH, tokenIn, amountIn, tokenOut, minOut, routesHash, nonce, deadline)
        );
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("NullTerminal Session"),
                keccak256("1"),
                block.chainid,
                address(this) // the EOA — binds the signatures to this specific account
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ── account compatibility for a delegated EOA (audit M6) ──────────────────
    // A 7702 authorization gives the EOA code, so every counterparty that branches on `code.length > 0`
    // stops treating it as an EOA: Permit2's SignatureVerification (and OZ SignatureChecker) take the
    // ERC-1271 path, and `safeTransferFrom` of an NFT calls the receiver hook. With neither implemented
    // and no fallback, those calls REVERT — silently breaking this repo's own Permit2 gasless flow and
    // all NFT receipts for anyone on the persistent raw-7702 path. These restore EOA-equivalent behaviour.

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

    /// @notice ERC-1271. The account IS the signer: under 7702 `address(this)` is the EOA whose key
    /// produced the signature, so a plain ECDSA recovery against it is exactly the EOA semantics that
    /// counterparties would have used before the delegation existed. Malleable/short signatures are
    /// rejected by `tryRecover` rather than reverting, so a bad signature returns the failure value.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == address(this)) return ERC1271_MAGIC;
        return 0xffffffff;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }

    /// @dev ERC-165: ERC165 itself, ERC721Receiver, ERC1155Receiver — some tokens check before sending.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x150b7a02 || id == 0x4e2312e0;
    }

    receive() external payable { }

    /// @dev Permissive no-op fallback: a plain EOA accepts ANY calldata without reverting, and a
    /// delegated account must keep doing so or unrelated integrations break on an unknown selector.
    /// Safe because it does nothing — every fund-moving path above is explicitly guarded.
    fallback() external payable { }
}
