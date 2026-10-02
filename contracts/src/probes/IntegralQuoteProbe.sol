// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IAlgebraPoolSwap {
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @title IntegralQuoteProbe — NEVER deployed. The engine puts this runtime code at a scratch address with an eth_call
///        state override and calls `quote`: it runs the pool's real `swap` (plugin hooks + dynamic fee included) and the
///        callback reverts with the two deltas before paying, so nothing moves and no quoter address is needed per venue.
/// @dev Same trick as Algebra's own QuoterV2, minus its pool-address derivation (Blackhole CL pools come from custom
///      deployers that a venue quoter may not know). A revert that is not the 64-byte delta pair bubbles up unchanged.
contract IntegralQuoteProbe {
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @return amount0 pool delta of token0 (positive = owed to the pool)
    /// @return amount1 pool delta of token1
    function quote(address pool, bool zeroToOne, int256 amountIn) external returns (int256 amount0, int256 amount1) {
        try IAlgebraPoolSwap(pool).swap(
            address(this), zeroToOne, amountIn, zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, ""
        ) {
            revert("swap did not call back");
        } catch (bytes memory reason) {
            if (reason.length != 64) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            (amount0, amount1) = abi.decode(reason, (int256, int256));
        }
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external pure {
        assembly {
            mstore(0, amount0Delta)
            mstore(32, amount1Delta)
            revert(0, 64)
        }
    }
}
