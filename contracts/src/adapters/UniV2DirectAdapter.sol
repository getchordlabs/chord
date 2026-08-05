// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface IUniV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title UniV2DirectAdapter
/// @notice Swaps directly on Uniswap V2 pools (no router needed)
/// @dev Calculates amountOut from reserves, transfers tokenIn to pool, calls pool.swap()
/// @dev L4 ASSUMPTION: this adapter hardcodes the canonical Uniswap V2 0.3% swap fee
///      (the 997/1000 factor below) and the pure constant-product x*y=k invariant.
///      It will MISPRICE any pool that deviates from these assumptions — e.g. forks with
///      a different fee tier, fee-on-transfer / rebasing tokens (where the amount the pool
///      actually receives differs from `amountIn`), or non-standard curve math. Only route
///      standard, non-fee-on-transfer 0.3% V2 pairs through this adapter. The pool's own
///      `swap()` k-check will revert on a too-optimistic `amountOut`, but mispriced quotes
///      can still cause failed txs or worse-than-quoted execution; slippage (minAmountOut)
///      in NullRouter remains the backstop.
/// @dev H1 (2026-08-05 audit): this was one of the TWO push-model adapters that did not even need a
///      callback to be drained — `:52` transferred the entire input straight to a caller-named
///      address, from a world-callable function. Fixed on both axes: `onlyRouter` (BaseAdapter) and
///      PROVENANCE — the pool must be the pair the factory pinned at construction returns for
///      (tokenIn, tokenOut), which also binds the pool to the router's own token pair.
contract UniV2DirectAdapter is IAdapter, BaseAdapter {
    /// @notice V2 factory whose pairs this adapter will trade — pinned at deploy.
    IUniV2Factory public immutable FACTORY;

    /// @notice extraData named something other than FACTORY's canonical pair for (tokenIn, tokenOut).
    error NotFactoryPair(address pool);

    constructor(address nullRouter_, address factory_) BaseAdapter(nullRouter_) {
        require(factory_ != address(0), "V2_ZERO_FACTORY");
        FACTORY = IUniV2Factory(factory_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        // H1 provenance: getPair is symmetric in V2, so one lookup pins BOTH the pool's authenticity
        // and its pair — a caller can no longer name any address, nor a real pool of another pair.
        if (pool == address(0) || FACTORY.getPair(tokenIn, tokenOut) != pool) {
            revert NotFactoryPair(pool);
        }
        IUniV2Pair pair = IUniV2Pair(pool);

        // Get reserves
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();

        bool zeroForOne = tokenIn == token0;
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // Calculate amountOut: dy = dx * 997 * reserveOut / (reserveIn * 1000 + dx * 997)
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

        // Transfer tokenIn directly to the pool
        TransferLib.safeTransfer(tokenIn, pool, amountIn);

        // Call swap
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        pair.swap(amount0Out, amount1Out, to, "");
    }
}
