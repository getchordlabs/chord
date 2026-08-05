// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter, PoolProvenance} from "./BaseAdapter.sol";

interface ISwapRouterDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title V3DeadlineAdapter
/// @notice Executes swaps on V3 forks that use the deadline-style SwapRouter
/// @dev Used for Capricorn, PancakeSwap V3, and other V3 forks with deadline param
///
///      H1 (2026-08-05 audit): same shape as PancakeV3Adapter — extraData carries only a `uint24 fee`,
///      the destination is the IMMUTABLE deadline-style SwapRouter, and the real gap was the
///      world-callable entrypoint (`onlyRouter` now). The CREATE2 derivation is defence-in-depth: it
///      proves the (tokenIn, tokenOut, fee) triple names a DEPLOYED pool of the pinned factory. ONE
///      deployment pairs with ONE router, so a single (factory, initCodeHash) pin is exact.
contract V3DeadlineAdapter is IAdapter, BaseAdapter {
    ISwapRouterDeadline public immutable ROUTER;
    /// @notice The fork factory this adapter's router settles against — pinned at deploy.
    address public immutable FACTORY;
    /// @notice keccak256 of the fork's pool creation code — per-fork, supplied by the deploy script.
    ///         Pass ZERO to use the factory's own `getPool` registry instead (equally authoritative,
    ///         and the honest option when the hash cannot be verified — never guess one).
    bytes32 public immutable POOL_INIT_CODE_HASH;

    /// @notice The (tokenIn, tokenOut, fee) triple does not name a deployed pool of FACTORY.
    error PoolNotCanonical(address derivedPool);

    constructor(address nullRouter_, address router_, address factory_, bytes32 poolInitCodeHash_)
        BaseAdapter(nullRouter_)
    {
        require(router_ != address(0) && factory_ != address(0), "V3_ZERO_ADDR");
        ROUTER = ISwapRouterDeadline(router_);
        FACTORY = factory_;
        POOL_INIT_CODE_HASH = poolInitCodeHash_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(uint24 fee)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        uint24 fee = abi.decode(extraData, (uint24));
        _requireCanonicalPool(tokenIn, tokenOut, fee);

        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);

        amountOut = ROUTER.exactInputSingle(
            ISwapRouterDeadline.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: to,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);

        // M5: forward any unconsumed input (partial fill on a thin pool) — this adapter is immutable
        // and ownerless, so anything left here is stranded forever. `to` is NullRouter, which
        // dust-sweeps it back to the user.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @dev H1 provenance: CREATE2 derivation onto deployed code, or the factory's own `getPool`
    ///      registry when no init-code hash was pinned. Tokens sorted the way V3 factories sort them.
    function _requireCanonicalPool(address tokenA, address tokenB, uint24 fee) internal view {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (POOL_INIT_CODE_HASH != bytes32(0)) {
            address pool = PoolProvenance.computeAddress(
                FACTORY, POOL_INIT_CODE_HASH, keccak256(abi.encode(token0, token1, fee))
            );
            if (pool.code.length == 0) revert PoolNotCanonical(pool);
            return;
        }
        (bool ok, bytes memory ret) = FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,uint24)", token0, token1, fee)
        );
        address registered = (ok && ret.length >= 32) ? abi.decode(ret, (address)) : address(0);
        if (registered == address(0)) revert PoolNotCanonical(registered);
    }
}
