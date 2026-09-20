// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Circle CCTP V2 TokenMessengerV2 (same address on every CCTP chain).
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/**
 * @title SwapAndBridgeCCTP
 * @notice One transaction for the origin side of a Swap V2 composed route on Circle's rail:
 *         pull `tokenIn` (or native), swap it into USDC through the pinned NullRouter with router
 *         calldata the API already builds, take a small fee, and burn the rest through CCTP V2 toward
 *         the destination domain — where our relayer (Arc) or the user (elsewhere) mints it.
 *
 *         Why it exists (docs/swap-v2-crosschain.md §6 / §10 P4): Circle's rail has no fee hook, so
 *         until now the CCTP corridor earned nothing and cost the user three signatures
 *         (approve tokenIn, swap, approve USDC + burn). Here the approve of USDC to the messenger is
 *         the contract's own, the swap and the burn are one call, and the fee is `feeBps` of the USDC
 *         that came out of the swap.
 *
 * @dev Non-custodial and permissionless: the contract holds nothing between calls, every parameter
 *      that moves money (router, USDC, messenger, fee recipient, fee bps) is immutable, and the only
 *      external calls are to those pinned addresses. The router calldata is opaque on purpose — the
 *      API builds it exactly as for a normal swap — but its OUTCOME is checked: the USDC delta of this
 *      contract must be ≥ `minUsdcOut` or the whole transaction reverts, so a wrong route, a wrong
 *      output token or a stale quote cannot burn less than the user agreed to. `mintRecipient` is
 *      supplied by the caller (bytes32 of their address) because a contract wallet may want a
 *      different recipient; the destination domain is caller-chosen too, Circle validates it.
 */
contract SwapAndBridgeCCTP is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BPS = 100; // 1 % hard cap, mirrors FeeCollector's cap
    uint32 public constant FAST_FINALITY = 1000; // CCTP V2 fast transfer

    address public immutable ROUTER;
    IERC20 public immutable USDC;
    ITokenMessengerV2 public immutable MESSENGER;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable FEE_BPS;

    event SwappedAndBurned(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcOut,
        uint256 fee,
        uint256 burned,
        uint32 destinationDomain,
        bytes32 mintRecipient
    );

    error ZeroAddress();
    error FeeTooHigh();
    error ZeroAmount();
    error BadValue();
    error RouterCallFailed(bytes reason);
    error InsufficientOutput(uint256 got, uint256 want);
    error NothingToBurn();

    constructor(address router, address usdc, address messenger, address feeRecipient, uint256 feeBps) {
        if (router == address(0) || usdc == address(0) || messenger == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeBps > 0 && feeRecipient == address(0)) revert ZeroAddress();
        ROUTER = router;
        USDC = IERC20(usdc);
        MESSENGER = ITokenMessengerV2(messenger);
        FEE_RECIPIENT = feeRecipient;
        FEE_BPS = feeBps;
    }

    /**
     * @notice Swap `amountIn` of `tokenIn` into USDC through the router and burn it toward `destinationDomain`.
     * @param tokenIn        ERC-20 to spend, or address(0) for the chain's native coin (sent as msg.value).
     * @param amountIn       Amount of `tokenIn` (must equal msg.value when native).
     * @param routerCalldata Calldata for the pinned router — built by the API for THIS contract as the
     *                       caller (the router delivers output to msg.sender = this contract). The API
     *                       encodes `minAmountOut`/deadline inside; `minUsdcOut` below is the second lock.
     * @param minUsdcOut     Minimum USDC the swap must produce (pre-fee) — reverts otherwise.
     * @param destinationDomain CCTP domain to burn toward.
     * @param mintRecipient  bytes32(address) that receives USDC on the destination.
     * @param maxFee         Circle's fee ceiling for the fast transfer (from Iris `/v2/burn/USDC/fees`).
     */
    function swapAndBurn(
        address tokenIn,
        uint256 amountIn,
        bytes calldata routerCalldata,
        uint256 minUsdcOut,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee
    ) external payable nonReentrant returns (uint256 burned) {
        if (amountIn == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();

        uint256 value;
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert BadValue();
            value = amountIn;
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).forceApprove(ROUTER, amountIn);
        }

        uint256 before = USDC.balanceOf(address(this));
        (bool ok, bytes memory reason) = ROUTER.call{ value: value }(routerCalldata);
        if (!ok) revert RouterCallFailed(reason);
        uint256 usdcOut = USDC.balanceOf(address(this)) - before;
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(ROUTER, 0);

        uint256 fee = (usdcOut * FEE_BPS) / 10_000;
        burned = usdcOut - fee;
        if (burned == 0 || burned <= maxFee) revert NothingToBurn();
        if (fee > 0) USDC.safeTransfer(FEE_RECIPIENT, fee);

        USDC.forceApprove(address(MESSENGER), burned);
        MESSENGER.depositForBurn(burned, destinationDomain, mintRecipient, address(USDC), bytes32(0), maxFee, FAST_FINALITY);

        emit SwappedAndBurned(msg.sender, tokenIn, amountIn, usdcOut, fee, burned, destinationDomain, mintRecipient);
    }

    /**
     * @notice Burn USDC the caller already holds (no swap) — the "leg 1 skipped" case, still one
     *         approve of the contract instead of the messenger, and still fee-bearing.
     */
    function burn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, uint256 maxFee)
        external
        nonReentrant
        returns (uint256 burned)
    {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 fee = (amount * FEE_BPS) / 10_000;
        burned = amount - fee;
        if (burned == 0 || burned <= maxFee) revert NothingToBurn();
        if (fee > 0) USDC.safeTransfer(FEE_RECIPIENT, fee);
        USDC.forceApprove(address(MESSENGER), burned);
        MESSENGER.depositForBurn(burned, destinationDomain, mintRecipient, address(USDC), bytes32(0), maxFee, FAST_FINALITY);
        emit SwappedAndBurned(msg.sender, address(USDC), amount, amount, fee, burned, destinationDomain, mintRecipient);
    }

    /// @dev Routers that unwrap to native would send value here; nothing in this contract wants it.
    receive() external payable {
        revert BadValue();
    }
}
