// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Balancer V3 Vault registry views. `isPoolRegistered` covers pool steps;
///         `isERC4626BufferInitialized` covers buffer (wrap/unwrap) steps — both live on
///         VaultExtension and are reached through the Vault's fallback.
interface IBalancerVaultRegistry {
    function isPoolRegistered(address pool) external view returns (bool);
    function isERC4626BufferInitialized(address wrappedToken) external view returns (bool);
}

/// @notice Balancer V3 AggregatorBatchRouter — multi-step (buffer) swaps, pre-fund-Vault model (no
///         Permit2/approval). For boosted pools whose registered tokens are ERC4626 wrappers: a raw→raw
///         swap goes wrap(raw→wn) → pool(wn→wn) → unwrap(wn→raw) as one path. Structs + signature verified
///         vs the deployed Monad artifact (20250507-v3-aggregator-batch-router).
interface IBalancerAggregatorBatchRouter {
    /// @dev isBuffer=true → `pool` is an ERC4626 buffer (wrapper); the step wraps/unwraps.
    struct SwapPathStep {
        address pool;
        address tokenOut;
        bool isBuffer;
    }

    struct SwapPathExactAmountIn {
        address tokenIn;
        SwapPathStep[] steps;
        uint256 exactAmountIn;
        uint256 minAmountOut;
    }

    function swapExactIn(SwapPathExactAmountIn[] memory paths, uint256 deadline, bytes calldata userData)
        external
        payable
        returns (uint256[] memory pathAmountsOut, address[] memory tokensOut, uint256[] memory amountsOut);
}

/// @title BalancerV3BoostedAdapter
/// @notice Executes Balancer V3 boosted/buffer swaps via the AggregatorBatchRouter on Monad.
/// @dev IMMUTABLE, stateless. Same pre-fund-Vault model as BalancerV3Adapter: transfer tokenIn to the
///      Vault, then swap — NO approval/Permit2. Output is credited to this adapter (msg.sender), which
///      forwards tokenOut to `to`. The full SwapPathStep[] is supplied by the engine in extraData (the
///      engine builds + verifies it from on-chain pool/buffer state — the adapter never derives it).
///
/// Vault:                 0xbA1333333333a1BA1108E8412f11850A5C319bA9
/// AggregatorBatchRouter: 0x7A2535f5fB47b8e44c02Ef5D9990588313fe8F05
///
/// extraData = abi.encode(IBalancerAggregatorBatchRouter.SwapPathStep[] steps).
///
/// H1 (2026-08-05 audit): the ENTIRE path came from caller-supplied extraData ("the engine builds +
/// verifies it" is a statement about the honest caller, not about who CAN call), and swap() was
/// world-callable. Fixed with `onlyRouter` (BaseAdapter) + per-step PROVENANCE against the same Vault
/// the swap pre-funds: pool steps must be registered pools, buffer steps must be initialised ERC4626
/// buffers, and the LAST step must land on the router's own `tokenOut`.
contract BalancerV3BoostedAdapter is IAdapter, BaseAdapter {
    /// @notice Balancer V3 singleton Vault — tokenIn is paid here up front.
    address public immutable VAULT;

    /// @notice AggregatorBatchRouter — settles the pre-funded multi-step swap (no approval).
    IBalancerAggregatorBatchRouter public immutable ROUTER;

    /// @notice A path step names a pool the Vault does not know.
    error PoolNotRegistered(address pool);
    /// @notice A buffer step names an ERC4626 wrapper with no initialised Vault buffer.
    error BufferNotInitialized(address wrappedToken);
    /// @notice Empty path, or the path does not end on the route's tokenOut.
    error PathNotBoundToRoute();

    constructor(address nullRouter_, address vault_, address router_) BaseAdapter(nullRouter_) {
        // NOTE: the AggregatorBatchRouter exposes no vault accessor (unlike the single-swap
        // AggregatorRouter), so we cannot cross-check ROUTER↔VAULT on-chain here. Both are supplied by the
        // deploy script from verified addresses; a mis-wire fails safe (the Vault settle reverts) and is
        // caught by the mandatory mainnet 2-way swap test.
        VAULT = vault_;
        ROUTER = IBalancerAggregatorBatchRouter(router_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(SwapPathStep[] steps). The path's tokenIn/exactAmountIn come from the
    ///      call args; minAmountOut=0 (NullRouter enforces the real slippage globally).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        IBalancerAggregatorBatchRouter.SwapPathStep[] memory steps =
            abi.decode(extraData, (IBalancerAggregatorBatchRouter.SwapPathStep[]));
        _requireValidPath(steps, tokenOut);

        // Aggregator model: pay the Vault up front, then swap. No approval/Permit2.
        TransferLib.safeTransfer(tokenIn, VAULT, amountIn);

        IBalancerAggregatorBatchRouter.SwapPathExactAmountIn[] memory paths =
            new IBalancerAggregatorBatchRouter.SwapPathExactAmountIn[](1);
        paths[0] = IBalancerAggregatorBatchRouter.SwapPathExactAmountIn({
            tokenIn: tokenIn,
            steps: steps,
            exactAmountIn: amountIn,
            minAmountOut: 0
        });

        (uint256[] memory pathAmountsOut,,) = ROUTER.swapExactIn(paths, block.timestamp, "");
        amountOut = pathAmountsOut[0];

        // Forward proceeds to the recipient (NullRouter / final receiver).
        if (to != address(this)) {
            TransferLib.safeTransfer(tokenOut, to, amountOut);
        }
    }

    /// @dev H1 provenance for a caller-supplied multi-step path. Every step is checked against the
    ///      SAME Vault the input is pre-paid to, so a step can only name real Balancer state; the
    ///      final step is bound to the route's tokenOut so the path cannot end somewhere else.
    ///      NOTE FOR DEPLOY: confirm `isERC4626BufferInitialized` against the deployed Monad Vault
    ///      (VaultExtension) in the mandatory both-ways mainnet verification — a selector mismatch
    ///      fails CLOSED (every boosted swap reverts), which is the safe direction but is still a
    ///      venue outage if it ships unverified.
    function _requireValidPath(
        IBalancerAggregatorBatchRouter.SwapPathStep[] memory steps,
        address tokenOut
    ) internal view {
        uint256 n = steps.length;
        if (n == 0 || steps[n - 1].tokenOut != tokenOut) revert PathNotBoundToRoute();
        for (uint256 i = 0; i < n; i++) {
            address target = steps[i].pool;
            if (steps[i].isBuffer) {
                if (!IBalancerVaultRegistry(VAULT).isERC4626BufferInitialized(target)) {
                    revert BufferNotInitialized(target);
                }
            } else if (!IBalancerVaultRegistry(VAULT).isPoolRegistered(target)) {
                revert PoolNotRegistered(target);
            }
        }
    }
}
