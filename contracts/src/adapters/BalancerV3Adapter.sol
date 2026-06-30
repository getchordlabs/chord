// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

/// @notice Balancer V3 AggregatorRouter — the "sender pays the Vault up front" router: no Permit2, no
///         token approval. The caller transfers tokenIn to the Vault, then the router settles the swap
///         against that balance and credits the output back to the caller. Verified vs the deployed
///         Monad artifact (20250218-v3-aggregator-router) + source commit 3995e954.
interface IBalancerAggregatorRouter {
    function swapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata userData
    ) external returns (uint256 amountOut);

    /// @notice The singleton Vault this router settles against (from RouterCommon).
    function getVault() external view returns (address);
}

/// @title BalancerV3Adapter
/// @notice Executes single-pool swaps on Balancer V3 via the AggregatorRouter on Monad.
/// @dev IMMUTABLE, stateless. Aggregator funding model: pre-fund the Vault with tokenIn, then swap —
///      NO approve/Permit2. The router credits tokenOut (and refunds any tokenIn leftover) to THIS
///      adapter (it is `msg.sender`), which forwards tokenOut to `to`. ERC20-only: NullRouter wraps
///      MON→WMON before any ERC20 adapter, so this never sees address(0); no `receive()` needed.
///
/// Vault:            0xbA1333333333a1BA1108E8412f11850A5C319bA9
/// AggregatorRouter: 0xc3ccacE87f6d3A81724075ADcb5ddd85a8A1bB68
///
/// extraData = abi.encode(address pool). Simple (non-boosted) single-pool path only. Boosted ERC4626
/// buffer paths go through a separate AggregatorBatchRouter flow (Phase 1), not this contract.
contract BalancerV3Adapter is IAdapter {
    /// @notice Balancer V3 singleton Vault — tokenIn is paid here up front.
    address public immutable VAULT;

    /// @notice AggregatorRouter — settles the pre-funded swap (no approval).
    IBalancerAggregatorRouter public immutable ROUTER;

    constructor(address vault_, address router_) {
        // The pre-fund flow transfers tokenIn to VAULT but settles via ROUTER — a mismatch would silently
        // strand funds in the wrong Vault. Pin them together at deploy: ROUTER must settle against vault_.
        require(IBalancerAggregatorRouter(router_).getVault() == vault_, "VAULT_MISMATCH");
        VAULT = vault_;
        ROUTER = IBalancerAggregatorRouter(router_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));

        // Aggregator model: pay the Vault up front, then swap. No approval/Permit2.
        TransferLib.safeTransfer(tokenIn, VAULT, amountIn);

        // minOut=0 and deadline=now — NullRouter enforces the real slippage + deadline globally before
        // this call. Output is credited to this adapter (it is the router's `sender`).
        amountOut = ROUTER.swapSingleTokenExactIn(pool, tokenIn, tokenOut, amountIn, 0, block.timestamp, "");

        // Forward proceeds to the recipient (NullRouter / final receiver).
        if (to != address(this)) {
            TransferLib.safeTransfer(tokenOut, to, amountOut);
        }
    }
}
