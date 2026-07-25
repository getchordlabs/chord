// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";

interface IUniV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev exactInput when amountSpecified > 0. Returns pool-perspective deltas:
    ///      positive = pool received (input owed), negative = pool paid (output).
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title UniV3GenericAdapter
/// @notice Generic direct-pool swap adapter for ANY standard Uniswap-V3-style concentrated-liquidity
///         pool — Uniswap V3, PancakeSwap V3, Pangolin V3, MondayTrade, Pinot, Noxa, Algebra, … . There
///         is NO per-fork SwapRouter: the swap EXECUTES DIRECTLY on the pool via pool.swap() and settles
///         the input token inside the swap callback. ONE deployment serves every current + future V3
///         fork, so a new fork becomes engine discovery-only (no new contract, no new deploy).
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn to this adapter BEFORE calling
///      swap(); this adapter NEVER transferFrom's the caller and holds no approvals. The pool pays the
///      output DIRECTLY to `to` (swap recipient), so the adapter ends every swap holding zero of both
///      tokens. minAmountOut / deadline / dust-sweep are enforced globally by NullRouter.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived on-chain from pool.token0().
///
///      SECURITY — callback gate via TRANSIENT storage (cancun): the pool being swapped is tstore'd
///      immediately before pool.swap and cleared the instant it returns. The swap callback requires
///      msg.sender == the tload'd pool, so it is invokable ONLY by the pool this adapter is actively
///      swapping on, and only within that transaction; outside a swap the slot reads zero and any stray
///      call reverts ("V3_BAD_CALLBACK"). Fork callbacks use DIFFERENT selectors
///      (uniswapV3SwapCallback / pancakeV3SwapCallback / algebraSwapCallback) but share the identical
///      (int256 amount0Delta, int256 amount1Delta, bytes data) ABI, so the named Uniswap callback covers
///      Uniswap-style forks and a `fallback` covers the rest — both settle through one path.
contract UniV3GenericAdapter is IAdapter {
    /// @dev Uniswap V3 sqrt-price bounds. Passing (MIN+1) for zeroForOne / (MAX-1) otherwise means
    ///      "no price limit" → the pool swaps the full exact-input amount.
    uint160 internal constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    /// @notice Transient slot holding the pool allowed to invoke the swap callback (zero outside swaps).
    bytes32 private constant EXPECTED_POOL_TSLOT = keccak256("nullterminal.univ3-generic.expected-pool");

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — any standard V3-style pool.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        // A too-large amountIn would wrap to a negative int256 → the pool would read it as an
        // exact-OUTPUT swap. Reject it (NullRouter never sends anywhere near this).
        require(amountIn <= uint256(type(int256).max), "V3_AMOUNT_OVERFLOW");
        address pool = abi.decode(extraData, (address));
        bool zeroForOne = tokenIn == IUniV3PoolMinimal(pool).token0();

        bytes32 tslot = EXPECTED_POOL_TSLOT;
        assembly {
            tstore(tslot, pool)
        }
        // recipient = `to`: the pool pays the output straight to the final receiver.
        (int256 amount0, int256 amount1) = IUniV3PoolMinimal(pool).swap(
            to,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1,
            abi.encode(tokenIn)
        );
        assembly {
            tstore(tslot, 0)
        }

        // Output = the token the pool PAID (its negative delta).
        int256 outDelta = zeroForOne ? amount1 : amount0;
        require(outDelta < 0, "V3_NO_OUTPUT");
        amountOut = uint256(-outDelta);
        tokenOut; // silence unused-param warning; direction is derived from token0 above
    }

    /// @notice Uniswap V3 swap callback — pays the pool the input it is owed. Uniswap-style forks
    ///         (incl. Pangolin, MondayTrade) call this selector directly.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _settle(amount0Delta, amount1Delta, data);
    }

    /// @notice Callback for V3 forks whose callback uses a DIFFERENT selector (e.g. pancakeV3SwapCallback,
    ///         algebraSwapCallback) but the identical (int256,int256,bytes) ABI. Routed here via fallback.
    fallback() external {
        (int256 amount0Delta, int256 amount1Delta, bytes memory data) =
            abi.decode(msg.data[4:], (int256, int256, bytes));
        _settle(amount0Delta, amount1Delta, data);
    }

    /// @dev Shared settlement: gate to the active pool, then push the OWED input (positive delta) to it.
    function _settle(int256 amount0Delta, int256 amount1Delta, bytes memory data) private {
        bytes32 tslot = EXPECTED_POOL_TSLOT;
        address expected;
        assembly {
            expected := tload(tslot)
        }
        require(expected != address(0) && msg.sender == expected, "V3_BAD_CALLBACK");

        // Exactly one delta is positive (the input the pool is owed). data = abi.encode(tokenIn).
        address tokenIn = abi.decode(data, (address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        require(owed > 0, "V3_NOTHING_OWED");
        TransferLib.safeTransfer(tokenIn, msg.sender, owed);
    }
}
