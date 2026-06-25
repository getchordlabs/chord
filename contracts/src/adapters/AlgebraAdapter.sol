// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAlgebraPool {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountSpecified,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title AlgebraAdapter
/// @notice Executes swaps on Algebra V4 pools (Atlantis DEX) via callback pattern
/// @dev Calls pool.swap() directly. Pool calls back algebraSwapCallback() to pull tokens.
contract AlgebraAdapter is IAdapter {
    // Min/max sqrt price limits (same as Uniswap V3)
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // M1: transient-storage slot holding the pool we are mid-swap with. Set right before
    // pool.swap(), checked in algebraSwapCallback(), and cleared after the swap returns.
    // EIP-1153 (tstore/tload) is available — pragma ^0.8.24 + cancun evm_version.
    // keccak256("nullterminal.algebra.expectedPool") truncated to a constant slot.
    uint256 private constant EXPECTED_POOL_SLOT =
        uint256(keccak256("nullterminal.algebra.expectedPool"));

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
        IAlgebraPool algebraPool = IAlgebraPool(pool);

        address token0 = algebraPool.token0();
        bool zeroToOne = tokenIn == token0;

        uint160 sqrtPriceLimit = zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        // Encode callback data: tokenIn + amountIn (adapter will transfer in callback)
        bytes memory callbackData = abi.encode(tokenIn, amountIn, msg.sender);

        // M1: record the exact pool we are about to call so the callback can
        // authenticate msg.sender == this pool (and reject arbitrary callers).
        _setExpectedPool(pool);

        (int256 amount0, int256 amount1) = algebraPool.swap(
            to,              // recipient gets output directly
            zeroToOne,
            int256(amountIn),
            sqrtPriceLimit,
            callbackData
        );

        // M1: clear the authorization once the swap (and its callback) completed.
        _setExpectedPool(address(0));

        // Output is the negative delta (tokens sent to recipient)
        amountOut = zeroToOne ? uint256(-amount1) : uint256(-amount0);
    }

    /// @dev Callback from Algebra pool — transfer tokenIn to pool
    function algebraSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // M1: only the pool we are actively swapping with may invoke this callback.
        // Without this an arbitrary caller could trigger a token transfer out of the adapter.
        require(msg.sender == _expectedPool(), "unauthorized callback");

        (address tokenIn, uint256 amountIn, address payer) = abi.decode(data, (address, uint256, address));

        // Transfer the required amount to the pool
        // Tokens are already in this adapter (transferred by NullRouter before swap())
        uint256 amountRequired = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        TransferLib.safeTransfer(tokenIn, msg.sender, amountRequired);
    }

    /// @dev M1: write the expected-pool authorization to transient storage (EIP-1153).
    function _setExpectedPool(address pool) private {
        uint256 slot = EXPECTED_POOL_SLOT;
        assembly {
            tstore(slot, pool)
        }
    }

    /// @dev M1: read the expected-pool authorization from transient storage (EIP-1153).
    function _expectedPool() private view returns (address pool) {
        uint256 slot = EXPECTED_POOL_SLOT;
        assembly {
            pool := tload(slot)
        }
    }
}
