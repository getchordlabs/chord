// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice nad.fun DEX pair factory (V2 fork, "NADLP") — `getPair` is the venue's own registry and
///         is symmetric in its arguments.
interface INadFunFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

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
/// @dev FEES (MEASURED from real pair Swap/Sync events — the pair verifies neither ABI nor source):
///      ASYMMETRIC.
///      · BUY (WMON in → token out): 1.6% on input — V2-style dy = dx·984·Ro/(Ri·1000+dx·984),
///        matches on-chain fills TO THE WEI.
///      · SELL (token in → WMON out): 0.25% on input THEN 1.35% on output (the pair transfers the
///        output-side fee to its collector inside swap()). Fitted exactly across sizes
///        (residual constant 5/32 of the naive-984 spread). A 1bp safety haircut keeps the k-check
///        green against any remaining rounding drift; NullRouter's minAmountOut stays the
///        user-facing backstop.
/// @dev extraData = abi.encode(address pool)
/// @dev H1 (2026-08-05 audit): `:67` was an UNCONDITIONAL safeTransfer of the entire input to a
///      caller-named address, from a world-callable function — the report's sharpest push-model
///      primitive alongside UniV2Direct. Fixed on both axes: `onlyRouter` (BaseAdapter) and
///      PROVENANCE against the nad.fun pair factory pinned at construction (`getPair`), which also
///      binds the pair to the router's own (tokenIn, tokenOut).
contract NadFunPairAdapter is IAdapter, BaseAdapter {
    address public immutable WMON;
    /// @notice nad.fun DEX pair factory (0xA25b1312… on Monad) — pinned at deploy.
    INadFunFactory public immutable FACTORY;

    /// @notice extraData named something other than FACTORY's canonical pair for (tokenIn, tokenOut).
    error NotFactoryPair(address pool);

    constructor(address nullRouter_, address wmon_, address factory_) BaseAdapter(nullRouter_) {
        require(wmon_ != address(0) && factory_ != address(0), "NADPAIR_ZERO_ADDR");
        WMON = wmon_;
        FACTORY = INadFunFactory(factory_);
    }

    /// @inheritdoc IAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        // H1 provenance: one symmetric lookup pins BOTH that the pair is factory-deployed and that it
        // is the pair for the tokens the router is pricing.
        if (pool == address(0) || FACTORY.getPair(tokenIn, tokenOut) != pool) {
            revert NotFactoryPair(pool);
        }
        INadFunPair pair = INadFunPair(pool);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool zeroForOne = tokenIn == pair.token0();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        if (tokenIn == WMON) {
            // BUY: 1.6% fee on input (exact).
            uint256 amountInWithFee = amountIn * 984;
            amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        } else {
            // SELL: 0.25% on input, then 1.35% on output, then a 1bp haircut for rounding safety.
            uint256 amountInWithFee = amountIn * 9975;
            amountOut = (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
            amountOut = (amountOut * 9865) / 10000;
            amountOut = (amountOut * 9999) / 10000;
        }

        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, to, "");
    }
}
