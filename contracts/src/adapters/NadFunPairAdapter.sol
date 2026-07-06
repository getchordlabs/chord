// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

interface INadFunPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title NadFunPairAdapter
/// @notice Swaps DIRECTLY on nad.fun DEX pairs ("NADLP", the V2 fork where nad.fun V2 tokens
///         graduate) — no nad.fun DEXRouter involved.
/// @dev Why direct: the official DEXRouter (0x0B79d7…) consults an internal registry before
///      swapping; that registry transiently returned empty for a freshly-graduated token
///      (2026-07-06, JAMES) making router-path swaps revert while the pair itself was live and
///      public. The pair's swap() is permissionless, so we price and swap against it directly —
///      deterministic, no third-party registry in the hot path.
/// @dev FEE: nad.fun pairs charge 1.6% (γ = 984/1000) — MEASURED from real pair Swap/Sync events
///      (4 samples, exact). NOT the canonical V2 0.3%. The pair's k-check reverts if this factor
///      is ever wrong-high; NullRouter's minAmountOut remains the user-facing backstop.
/// @dev extraData = abi.encode(address pool)
contract NadFunPairAdapter is IAdapter {
    /// @inheritdoc IAdapter
    function swap(
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        INadFunPair pair = INadFunPair(pool);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool zeroForOne = tokenIn == pair.token0();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // dy = dx·984·reserveOut / (reserveIn·1000 + dx·984)  — 1.6% pair fee
        uint256 amountInWithFee = amountIn * 984;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, to, "");
    }
}
