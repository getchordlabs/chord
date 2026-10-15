// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { INullRouter } from "./interfaces/INullRouter.sol";

/// @dev Native-out multi-hop overload of NullRouter (not in INullRouter).
interface INullRouterMultiHopNative2 {
    function multiHopSwap(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        INullRouter.RouteStep[] calldata routes,
        address referrer,
        bool unwrapOutput
    ) external payable returns (uint256 amountOut);
}

/// @dev Minimal canonical Permit2 SignatureTransfer surface.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

/// @title GaslessEntryPermit2
/// @notice One-signature gasless swaps. The user signs a SINGLE Permit2
/// `permitWitnessTransferFrom` whose witness binds the swap economics (tokenOut,
/// minAmountOut, relayerFee); a whitelisted relayer submits it, pays the gas, and
/// is compensated from the swap OUTPUT. This replaces the two signatures the
/// EIP-2612 GaslessEntry needs (permit + order) with one, and works for ANY
/// ERC20 — not just EIP-2612 permit tokens.
///
/// Safety — this contract never holds a standing allowance and never has
/// standing authority over user funds:
///   * Permit2 SignatureTransfer is SINGLE-USE per nonce (not an allowance), so
///     each swap requires a fresh user signature. Permit2's bitmap is UNORDERED,
///     though, so that alone does NOT give the "at most one live authorisation"
///     property the EIP-2612 entry has (audit 2026-08-05 M3): the FE mints a
///     random nonce per signature, so a user who re-signs after a 502 or a quote
///     refresh left 2-3 signatures independently redeemable for their full 600 s
///     window — and, having zero native gas by definition, could not call
///     `Permit2.invalidateUnorderedNonces` to cancel any of them. This entry
///     therefore keeps its OWN sequential nonce, bound into the witness: signing
///     order N+1 makes every outstanding order ≤ N unexecutable.
///   * The only standing approval is the user's `token.approve(Permit2, …)` to
///     the canonical, audited Permit2 — never to this contract.
///   * The witness binds tokenOut/minAmountOut/relayerFee, so a malicious relayer
///     can only decline or pick a suboptimal-but-floor-clearing route; it can
///     never redirect output, inflate its fee, or change the pair. The Permit2
///     signature's spender is this contract, so only this contract can spend it.
///   * Router approval is exact-amount, granted+revoked per swap; FOT inputs are
///     rejected (balance-delta check); the user receives everything above the
///     exact signed relayer fee; minAmountOut is enforced on the net receive.
contract GaslessEntryPermit2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RouteKind {
        Single,
        Split,
        MultiHop
    }

    struct SwapWitness {
        address tokenOut; // address(0) = deliver native MON
        uint256 minAmountOut; // minimum the USER receives AFTER the relayer fee
        uint256 relayerFee; // exact relayer compensation, in tokenOut units
        uint256 nonce; // THIS entry's sequential nonce — must equal nonces[owner] (M3)
    }

    // EIP-712 witness type. The referenced structs are ordered alphabetically
    // (SwapWitness, then TokenPermissions) per EIP-712, exactly as Permit2 expects.
    //
    // ⚠️ THREE-SIDED SEAM — the typestring below is BYTE-MATCHED off-chain. Any change to the signed
    // struct must land in the same change set as:
    //   1. packages/keeper/src/relayer.ts:184  — `struct SwapWitness { … }` in PERMIT2_ENTRY_ABI
    //      (+ :186 `execute(...)` if the arg list moves) and the `witness` Zod schema it validates.
    //   2. packages/web/src/hooks/useGasless.ts:238 — the `SwapWitness` EIP-712 type array, the
    //      `message.witness` object, and the JSON body posted to /v1/gasless/swap.
    // A mismatch does not fail loudly: Permit2 recomputes a DIFFERENT witness hash and the swap reverts
    // with a signature error that looks like a user problem.
    bytes32 public constant WITNESS_TYPEHASH =
        keccak256("SwapWitness(address tokenOut,uint256 minAmountOut,uint256 relayerFee,uint256 nonce)");
    string public constant WITNESS_TYPE_STRING =
        "SwapWitness witness)SwapWitness(address tokenOut,uint256 minAmountOut,uint256 relayerFee,uint256 nonce)TokenPermissions(address token,uint256 amount)";

    /// @notice Hard ceiling on `maxFeeBps` — matches the band the sibling stock-sell relayer already
    /// enforces off-chain (relayer.ts: "never eat more than 20% of the output"). The owner can only
    /// TIGHTEN the band, never widen it past this (audit L4).
    uint256 public constant MAX_FEE_BPS_CEILING = 2_000;

    ISignatureTransfer public immutable permit2;
    INullRouter public immutable router;
    address public immutable wmon;

    mapping(address => bool) public isRelayer;
    /// @notice Sequential per-user nonce — the single-live-authorisation bound (M3).
    mapping(address => uint256) public nonces;
    /// @notice Upper bound on `relayerFee` as a share of what the swap actually produced (L4).
    uint256 public maxFeeBps;

    event GaslessSwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 userReceived,
        uint256 relayerFee,
        uint256 nonce
    );
    event RelayerSet(address indexed relayer, bool allowed);
    event MaxFeeBpsSet(uint256 bps);

    error NotRelayer();
    error InvalidParams();
    error InvalidRoutePlan();
    error BadEscrowAmount();
    error InsufficientUserOutput(uint256 got, uint256 floor);
    error NativeTransferFailed();
    error UnexpectedNative();
    error BadNonce(uint256 got, uint256 expected);
    error FeeOutOfBand(uint256 fee, uint256 received);

    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(address permit2_, address router_, address wmon_, address owner_) Ownable(owner_) {
        if (permit2_ == address(0) || router_ == address(0) || wmon_ == address(0)) revert InvalidParams();
        permit2 = ISignatureTransfer(permit2_);
        router = INullRouter(router_);
        wmon = wmon_;
        maxFeeBps = MAX_FEE_BPS_CEILING;
        emit MaxFeeBpsSet(MAX_FEE_BPS_CEILING);
    }

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        if (relayer == address(0)) revert InvalidParams();
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    /// @notice Tighten the relayer-fee band. Cannot be raised above MAX_FEE_BPS_CEILING.
    function setMaxFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS_CEILING) revert InvalidParams();
        maxFeeBps = bps;
        emit MaxFeeBpsSet(bps);
    }

    /// @notice The witness hash the FE/relayer must reproduce for the Permit2 signature.
    function witnessHash(SwapWitness calldata w) public pure returns (bytes32) {
        return keccak256(abi.encode(WITNESS_TYPEHASH, w.tokenOut, w.minAmountOut, w.relayerFee, w.nonce));
    }

    /// @notice Execute a one-signature gasless swap.
    /// @param permit  Permit2 PermitTransferFrom — permitted.token = tokenIn, permitted.amount = amountIn.
    /// @param owner   The user who signed (funds pulled from here, output delivered here).
    /// @param w       The swap witness the signature commits to.
    /// @param signature The single Permit2 witness signature.
    /// @param routes  Route plan from the routing engine (relayer-supplied; router re-validates).
    /// @param kind    Router entrypoint the plan targets.
    /// @param referrer Forwarded to the router's referral split.
    function execute(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address owner,
        SwapWitness calldata w,
        bytes calldata signature,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind,
        address referrer
    ) external onlyRelayer nonReentrant {
        address tokenIn = permit.permitted.token;
        uint256 amountIn = permit.permitted.amount;
        if (amountIn == 0 || tokenIn == address(0)) revert InvalidParams();
        if (tokenIn == w.tokenOut) revert InvalidParams();
        if (routes.length == 0) revert InvalidRoutePlan();

        // M3: OUR sequential nonce, consumed before anything moves. Permit2's own unordered bitmap only
        // stops the SAME signature twice; this is what makes a superseded signature unexecutable, so a
        // gasless user (who cannot afford to cancel anything) never has two live authorisations.
        if (w.nonce != nonces[owner]) revert BadNonce(w.nonce, nonces[owner]);
        unchecked {
            nonces[owner] = w.nonce + 1;
        }

        bool nativeOut = w.tokenOut == address(0);
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != tokenIn) revert InvalidRoutePlan();
            address lastOut = routes[routes.length - 1].tokenOut;
            if (nativeOut ? lastOut != wmon : lastOut != w.tokenOut) revert InvalidRoutePlan();
        }

        // ---- pull input via a SINGLE Permit2 witness signature ----
        // Permit2 verifies the signature over (permitted, spender=this, nonce, deadline, witness),
        // enforces the single-use nonce + deadline, and transfers exactly amountIn to this contract.
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        permit2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amountIn }),
            owner,
            witnessHash(w),
            WITNESS_TYPE_STRING,
            signature
        );
        if (IERC20(tokenIn).balanceOf(address(this)) - balBefore != amountIn) {
            revert BadEscrowAmount(); // fee-on-transfer input breaks accounting
        }

        // ---- swap through the router (scoped exact approval) ----
        // Router-level floor = user floor + relayer fee, so the user's post-fee amount
        // can never dip below what they signed.
        uint256 routerMinOut = w.minAmountOut + w.relayerFee;
        uint256 outBefore = _balanceOf(w.tokenOut);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        if (kind == RouteKind.Single) {
            if (routes.length != 1) revert InvalidRoutePlan();
            router.swap(tokenIn, w.tokenOut, amountIn, routerMinOut, block.timestamp, routes[0], referrer);
        } else if (kind == RouteKind.Split) {
            router.splitSwap(tokenIn, w.tokenOut, amountIn, routerMinOut, block.timestamp, routes, referrer);
        } else if (nativeOut) {
            INullRouterMultiHopNative2(address(router))
                .multiHopSwap(amountIn, routerMinOut, block.timestamp, routes, referrer, true);
        } else {
            router.multiHopSwap(amountIn, routerMinOut, block.timestamp, routes, referrer);
        }

        IERC20(tokenIn).forceApprove(address(router), 0);

        // ---- settle: user gets everything above the exact relayer fee ----
        uint256 received = _balanceOf(w.tokenOut) - outBefore;
        if (received < routerMinOut) revert InsufficientUserOutput(received, routerMinOut);
        // L4: the fee is exact and user-signed, but nothing related it to the trade — a malicious FE
        // could sign someone into relayerFee = 99% of output with minAmountOut = 1. Band it against what
        // the swap actually produced, the same check the stock-sell relayer already does off-chain.
        if (w.relayerFee * 10_000 > received * maxFeeBps) revert FeeOutOfBand(w.relayerFee, received);
        uint256 userAmount = received - w.relayerFee;

        _send(w.tokenOut, owner, userAmount);
        if (w.relayerFee > 0) _send(w.tokenOut, msg.sender, w.relayerFee);

        emit GaslessSwapExecuted(owner, tokenIn, w.tokenOut, amountIn, userAmount, w.relayerFee, permit.nonce);
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = payable(to).call{ value: amount }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Native MON only ever arrives from the router's native-out settlement.
    receive() external payable {
        if (msg.sender != address(router)) revert UnexpectedNative();
    }
}
