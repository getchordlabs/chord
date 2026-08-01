// SPDX-License-Identifier: UNLICENSED
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
///     each swap requires a fresh user signature — same per-trade risk as the
///     EIP-2612 flow, one signature instead of two.
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
    }

    // EIP-712 witness type. The referenced structs are ordered alphabetically
    // (SwapWitness, then TokenPermissions) per EIP-712, exactly as Permit2 expects.
    bytes32 public constant WITNESS_TYPEHASH =
        keccak256("SwapWitness(address tokenOut,uint256 minAmountOut,uint256 relayerFee)");
    string public constant WITNESS_TYPE_STRING =
        "SwapWitness witness)SwapWitness(address tokenOut,uint256 minAmountOut,uint256 relayerFee)TokenPermissions(address token,uint256 amount)";

    ISignatureTransfer public immutable permit2;
    INullRouter public immutable router;
    address public immutable wmon;

    mapping(address => bool) public isRelayer;

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

    error NotRelayer();
    error InvalidParams();
    error InvalidRoutePlan();
    error BadEscrowAmount();
    error InsufficientUserOutput(uint256 got, uint256 floor);
    error NativeTransferFailed();
    error UnexpectedNative();

    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(address permit2_, address router_, address wmon_, address owner_) Ownable(owner_) {
        if (permit2_ == address(0) || router_ == address(0) || wmon_ == address(0)) revert InvalidParams();
        permit2 = ISignatureTransfer(permit2_);
        router = INullRouter(router_);
        wmon = wmon_;
    }

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        if (relayer == address(0)) revert InvalidParams();
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    /// @notice The witness hash the FE/relayer must reproduce for the Permit2 signature.
    function witnessHash(SwapWitness calldata w) public pure returns (bytes32) {
        return keccak256(abi.encode(WITNESS_TYPEHASH, w.tokenOut, w.minAmountOut, w.relayerFee));
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
