// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {INullRouter} from "./interfaces/INullRouter.sol";

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

/// @title GaslessEntry
/// @notice Gasless swaps for users with ZERO native MON: the user signs (a) an
/// EIP-2612 permit for tokenIn and (b) an EIP-712 GaslessOrder; a whitelisted
/// relayer submits both, pays the gas, and is compensated from the swap OUTPUT.
///
/// The classic onboarding dead-end this solves: someone bridges USDC to Monad
/// but holds no MON — they cannot even pay gas to swap for it. With tokenOut =
/// address(0) the router's native-out path delivers MON, so one signature both
/// buys the token and funds future gas.
///
/// Trust model mirrors NullOrderBook: the relayer supplies ONLY a route plan.
/// Everything economic — user, pair, amount, the user's post-fee floor
/// (minAmountOut) and the exact relayer fee — is SIGNED BY THE USER. The router
/// re-validates route shape + its adapter whitelist. A malicious relayer can
/// only decline to relay or pick a suboptimal-but-floor-clearing route.
///
/// Fund safety: exact-amount approval to the router granted+revoked per swap;
/// FOT tokens rejected; output measured by balance delta; surplus above
/// floor+fee goes to the USER (relayer fee is exact, never inflated);
/// per-user sequential nonces + deadline stop replay.
contract GaslessEntry is EIP712, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RouteKind {
        Single,
        Split,
        MultiHop
    }

    struct GaslessOrder {
        address user;
        address tokenIn; // ERC20 with EIP-2612 permit (gasless users can't wrap native)
        address tokenOut; // address(0) = deliver native MON
        uint256 amountIn;
        uint256 minAmountOut; // minimum the USER receives AFTER the relayer fee
        uint256 relayerFee; // exact relayer compensation, in tokenOut units
        uint256 deadline;
        uint256 nonce; // must equal nonces[user]
    }

    struct PermitData {
        uint256 value; // must cover amountIn
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "GaslessOrder(address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 relayerFee,uint256 deadline,uint256 nonce)"
    );

    /// @notice Hard ceiling on `maxFeeBps` — matches the band the sibling stock-sell relayer already
    /// enforces off-chain (relayer.ts: "never eat more than 20% of the output"). The owner can only
    /// TIGHTEN the band, never widen it past this (audit L4).
    uint256 public constant MAX_FEE_BPS_CEILING = 2_000;

    INullRouter public immutable router;
    address public immutable wmon;

    mapping(address => uint256) public nonces;
    mapping(address => bool) public isRelayer;
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

    error FeeOutOfBand(uint256 fee, uint256 received);
    error NotRelayer();
    error Expired();
    error BadNonce();
    error BadSignature();
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

    constructor(address router_, address wmon_, address owner_)
        EIP712("NullTerminal Gasless", "1")
        Ownable(owner_)
    {
        if (router_ == address(0) || wmon_ == address(0)) revert InvalidParams();
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

    /// @notice EIP-712 digest the user signs — exposed for FE/relayer parity.
    function orderDigest(GaslessOrder calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.user,
                    o.tokenIn,
                    o.tokenOut,
                    o.amountIn,
                    o.minAmountOut,
                    o.relayerFee,
                    o.deadline,
                    o.nonce
                )
            )
        );
    }

    /// @notice Execute a signed gasless order through the NullRouter.
    /// @param o        The user-signed order.
    /// @param sig      User's EIP-712 signature over orderDigest(o).
    /// @param p        User's EIP-2612 permit for tokenIn → this contract.
    /// @param routes   Route plan from the routing engine (relayer-supplied).
    /// @param kind     Router entrypoint the plan targets.
    /// @param referrer Forwarded to the router's referral split (relayer may
    ///                 set its own integrator address here).
    function execute(
        GaslessOrder calldata o,
        bytes calldata sig,
        PermitData calldata p,
        INullRouter.RouteStep[] calldata routes,
        RouteKind kind,
        address referrer
    ) external onlyRelayer nonReentrant {
        // ---- order validation ----
        if (block.timestamp > o.deadline) revert Expired();
        if (o.nonce != nonces[o.user]) revert BadNonce();
        if (o.amountIn == 0 || o.tokenIn == address(0)) revert InvalidParams();
        if (o.tokenIn == o.tokenOut) revert InvalidParams();
        if (routes.length == 0) revert InvalidRoutePlan();
        if (ECDSA.recover(orderDigest(o), sig) != o.user) revert BadSignature();
        nonces[o.user] = o.nonce + 1;

        bool nativeOut = o.tokenOut == address(0);
        if (kind == RouteKind.MultiHop) {
            if (routes[0].tokenIn != o.tokenIn) revert InvalidRoutePlan();
            address lastOut = routes[routes.length - 1].tokenOut;
            if (nativeOut ? lastOut != wmon : lastOut != o.tokenOut) revert InvalidRoutePlan();
        }

        // ---- pull input via permit (skip permit if allowance already covers) ----
        if (IERC20(o.tokenIn).allowance(o.user, address(this)) < o.amountIn) {
            if (p.value < o.amountIn) revert InvalidParams();
            // A front-run permit() consumes the sig but leaves the allowance we
            // need — tolerate failure and let the allowance check below decide.
            try IERC20Permit(o.tokenIn).permit(o.user, address(this), p.value, p.deadline, p.v, p.r, p.s) {}
                catch {}
        }
        uint256 balBefore = IERC20(o.tokenIn).balanceOf(address(this));
        IERC20(o.tokenIn).safeTransferFrom(o.user, address(this), o.amountIn);
        if (IERC20(o.tokenIn).balanceOf(address(this)) - balBefore != o.amountIn) {
            revert BadEscrowAmount(); // fee-on-transfer input breaks accounting
        }

        // ---- swap through the router (typed args; scoped exact approval) ----
        // Router-level floor = user floor + relayer fee, so the post-fee amount
        // the user receives can never dip below what they signed.
        uint256 routerMinOut = o.minAmountOut + o.relayerFee;
        uint256 outBefore = _balanceOf(o.tokenOut);
        IERC20(o.tokenIn).forceApprove(address(router), o.amountIn);

        if (kind == RouteKind.Single) {
            if (routes.length != 1) revert InvalidRoutePlan();
            router.swap(
                o.tokenIn, o.tokenOut, o.amountIn, routerMinOut, block.timestamp, routes[0], referrer
            );
        } else if (kind == RouteKind.Split) {
            router.splitSwap(
                o.tokenIn, o.tokenOut, o.amountIn, routerMinOut, block.timestamp, routes, referrer
            );
        } else if (nativeOut) {
            INullRouterMultiHopNative2(address(router)).multiHopSwap(
                o.amountIn, routerMinOut, block.timestamp, routes, referrer, true
            );
        } else {
            router.multiHopSwap(o.amountIn, routerMinOut, block.timestamp, routes, referrer);
        }

        IERC20(o.tokenIn).forceApprove(address(router), 0);

        // ---- settle: user gets everything above the exact relayer fee ----
        uint256 received = _balanceOf(o.tokenOut) - outBefore;
        if (received < routerMinOut) revert InsufficientUserOutput(received, routerMinOut);
        // L4: the fee is exact and user-signed, but nothing related it to the trade — a malicious FE
        // could sign someone into relayerFee = 99% of output with minAmountOut = 1. Band it against what
        // the swap actually produced, the same check the stock-sell relayer already does off-chain.
        if (o.relayerFee * 10_000 > received * maxFeeBps) revert FeeOutOfBand(o.relayerFee, received);
        uint256 userAmount = received - o.relayerFee;

        _send(o.tokenOut, o.user, userAmount);
        if (o.relayerFee > 0) _send(o.tokenOut, msg.sender, o.relayerFee);

        emit GaslessSwapExecuted(o.user, o.tokenIn, o.tokenOut, o.amountIn, userAmount, o.relayerFee, o.nonce);
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

    /// @dev Native MON only ever arrives from the router's native-out settlement.
    receive() external payable {
        if (msg.sender != address(router)) revert UnexpectedNative();
    }
}
