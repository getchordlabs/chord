// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Algebra factory pool registry. `poolByPair` is written for BOTH token orderings when a
///         pool is created, so either lookup is authoritative; we accept either to stay ordering-
///         agnostic across Algebra generations.
interface IAlgebraFactory {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}

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
///
///      H1 (2026-08-05 audit): `pool` arrives in caller-supplied extraData, so the transient callback
///      gate below was armed to whatever address the caller named — it authenticated the callback,
///      not the pool. Now: `onlyRouter` (BaseAdapter) + PROVENANCE against the Algebra factory pinned
///      at construction (`poolByPair`, an on-chain registry — preferred over CREATE2 here because
///      Algebra's pool deployer/init-code varies by generation while the registry never does).
contract AlgebraAdapter is IAdapter, BaseAdapter {
    /// @notice Algebra factory (Atlantis on Monad), pinned at deploy — the pool registry we trust.
    IAlgebraFactory public immutable FACTORY;

    /// @notice extraData named a pool the pinned Algebra factory does not know about.
    error PoolNotRegistered(address pool);

    constructor(address nullRouter_, address factory_) BaseAdapter(nullRouter_) {
        require(factory_ != address(0), "ALGEBRA_ZERO_FACTORY");
        FACTORY = IAlgebraFactory(factory_);
    }

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
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        IAlgebraPool algebraPool = IAlgebraPool(pool);

        address token0 = algebraPool.token0();
        address token1 = algebraPool.token1();
        // H1 provenance: the factory — not the pool's own claim — decides whether this is a real
        // Algebra pool. Reading token0/token1 off the pool is only safe because of this check.
        _requireRegisteredPool(pool, token0, token1);

        bool zeroToOne = tokenIn == token0;
        // Bind the router's economics to the pool's actual pair (the router prices and pays out in
        // `tokenOut`; nothing previously tied that to the pool being swapped).
        require(
            zeroToOne ? tokenOut == token1 : (tokenIn == token1 && tokenOut == token0),
            "ALGEBRA_PAIR_MISMATCH"
        );

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

        // Output is the negative delta (tokens sent to recipient).
        // H1/(c): the sign check was MISSING here while its sibling UniV3GenericAdapter:84 has it —
        // a pool returning +1 made uint256(-amount1) evaluate to type(uint256).max, i.e. an adapter
        // reporting an infinite fill to the router (M1's over-reporting primitive, no fake pool
        // needed once the pool is any Algebra-shaped contract).
        int256 outDelta = zeroToOne ? amount1 : amount0;
        require(outDelta < 0, "ALGEBRA_NO_OUTPUT");
        amountOut = uint256(-outDelta);

        // M5: partial fill (thin pool exhausts its liquidity) leaves the unspent input on this
        // IMMUTABLE, OWNERLESS adapter forever. Sweep it to `to` (= NullRouter, which dust-sweeps it
        // back to the user), mirroring LfjPoeAdapter rather than reverting an otherwise-valid fill.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @dev H1 provenance: accept the pool only if the pinned factory's registry maps its own pair to
    ///      it. Both orderings are tried — Algebra writes poolByPair for token0/token1 AND the
    ///      reverse, and being ordering-agnostic keeps this correct across generations.
    function _requireRegisteredPool(address pool, address token0, address token1) internal view {
        if (FACTORY.poolByPair(token0, token1) == pool) return;
        if (FACTORY.poolByPair(token1, token0) == pool) return;
        revert PoolNotRegistered(pool);
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
