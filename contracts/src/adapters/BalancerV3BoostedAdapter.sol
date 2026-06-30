// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

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

    /// @notice The singleton Vault this router settles against (from RouterCommon).
    function getVault() external view returns (address);
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
contract BalancerV3BoostedAdapter is IAdapter {
    /// @notice Balancer V3 singleton Vault — tokenIn is paid here up front.
    address public immutable VAULT;

    /// @notice AggregatorBatchRouter — settles the pre-funded multi-step swap (no approval).
    IBalancerAggregatorBatchRouter public immutable ROUTER;

    constructor(address vault_, address router_) {
        require(IBalancerAggregatorBatchRouter(router_).getVault() == vault_, "VAULT_MISMATCH");
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
    ) external override returns (uint256 amountOut) {
        IBalancerAggregatorBatchRouter.SwapPathStep[] memory steps =
            abi.decode(extraData, (IBalancerAggregatorBatchRouter.SwapPathStep[]));

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
}
