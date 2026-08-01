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
        mapping(address => uint256) remainingCap;
    }
    // keccak256(abi.encode(uint256(keccak256("nullterminal.session.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SESSION_SLOT = 0xcfac13c1098f5578e7cd69e27b116684fce86d87a76fda0b94b5180cbeceb500;

    function _s() private pure returns (SessionStorage storage s) {
        assembly {
            s.slot := SESSION_SLOT
        }
    }

    // ── config (immutable — a single trusted relayer for the MVP) ─────────────
    INullRouter public immutable router;
    address public immutable relayer;
    address public immutable wmon;

    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "SessionSwap(address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,bytes32 routesHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event SessionGranted(address indexed eoa, address indexed sessionKey, uint64 expiry);
    event SessionRevoked(address indexed eoa);
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
    error BadSessionSig();
    error BadRelayerSig();
    error InvalidRoutePlan();
    error InsufficientOutput();

    constructor(address router_, address relayer_, address wmon_) {
        if (router_ == address(0) || relayer_ == address(0) || wmon_ == address(0)) revert BadParams();
        router = INullRouter(router_);
        relayer = relayer_;
        wmon = wmon_;
    }

    // ── grant / revoke — only the EOA itself (7702 self-call) ─────────────────
    function grantSession(address sessionKey, uint64 expiry, address[] calldata tokens, uint256[] calldata caps)
        external
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (sessionKey == address(0) || expiry <= block.timestamp || tokens.length != caps.length) revert BadParams();
        SessionStorage storage s = _s();
        // Clear any prior token caps this call doesn't set is the caller's job; we overwrite the listed ones.
        s.sessionKey = sessionKey;
        s.expiry = expiry;
        s.nonce = 0;
        for (uint256 i = 0; i < tokens.length;) {
            s.remainingCap[tokens[i]] = caps[i]; // cap == 0 ⇒ token not allow-listed
            unchecked {
                ++i;
            }
        }
        emit SessionGranted(address(this), sessionKey, expiry);
    }

    function revokeSession(address[] calldata tokens) external {
        if (msg.sender != address(this)) revert OnlySelf();
        SessionStorage storage s = _s();
        s.sessionKey = address(0);
        s.expiry = 0;
        for (uint256 i = 0; i < tokens.length;) {
            s.remainingCap[tokens[i]] = 0;
            unchecked {
                ++i;
            }
        }
        emit SessionRevoked(address(this));
    }

    // ── views (FE reads remaining cap / expiry / nonce) ───────────────────────
    function sessionInfo() external view returns (address sessionKey, uint64 expiry, uint64 nonce) {
        SessionStorage storage s = _s();
        return (s.sessionKey, s.expiry, s.nonce);
    }

    function remainingCap(address token) external view returns (uint256) {
        return _s().remainingCap[token];
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
    ) external {
        SessionStorage storage s = _s();
        if (block.timestamp > deadline || block.timestamp > s.expiry) revert SessionExpired();
        if (nonce != s.nonce) revert BadNonce();
        if (amountIn == 0 || tokenIn == address(0) || tokenIn == tokenOut || routes.length == 0) {
            revert InvalidRoutePlan();
        }

        // Digest binds every economic term + the exact route; BOTH parties sign it.
        bytes32 digest =
            _digest(tokenIn, amountIn, tokenOut, minOut, keccak256(abi.encode(routes, kind)), nonce, deadline);
        if (ECDSA.recover(digest, sessionSig) != s.sessionKey || s.sessionKey == address(0)) revert BadSessionSig();
        if (ECDSA.recover(digest, relayerSig) != relayer) revert BadRelayerSig();

        // Cap doubles as the allow-list: a token with 0 remaining cap can't be spent.
        uint256 cap = s.remainingCap[tokenIn];
        if (cap < amountIn) revert CapExceeded();
        unchecked {
            s.remainingCap[tokenIn] = cap - amountIn;
            s.nonce = s.nonce + 1;
        }

        // ROUTER-ONLY: approve exact + swap; output is delivered to the EOA (address(this)). We never
        // move funds anywhere else, so a session can only ever swap the user's tokens back to the user.
        bool nativeOut = tokenOut == address(0);
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != tokenIn) revert InvalidRoutePlan();
            address lastOut = routes[routes.length - 1].tokenOut;
            if (nativeOut ? lastOut != wmon : lastOut != tokenOut) revert InvalidRoutePlan();
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

    receive() external payable { }
}
