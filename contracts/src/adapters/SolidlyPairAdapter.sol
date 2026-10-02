// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface ISolidlyPair {
    function token0() external view returns (address);
    function stable() external view returns (bool);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ISolidlyFactory {
    /// @dev Solidly V1 / Blackhole V1 name.
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address);
    /// @dev Velodrome V2 / Aerodrome V2 name (their factories have no `getPair`).
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

interface IERC20BalS {
    function balanceOf(address) external view returns (uint256);
}

/// @title SolidlyPairAdapter
/// @notice Swaps directly on a Solidly-style pair (volatile x·y=k or stable x³y+y³x=k) — written for Blackhole
///         V1 on Avalanche (factory 0xfe926062…, "vAMM-…" / "sAMM-…" pairs, per-pair fee from the factory,
///         volatile 70 bps / stable 5 bps on 2026-10-02). The UniV2 adapters hardcode the 0.3 % x·y=k curve and
///         would misprice both: a 70-bps volatile pair reverts its K check, a stable pair is on another curve.
///         Here the PAIR prices the trade: `pair.getAmountOut(received, tokenIn)` applies the pair's own fee and
///         curve, so one adapter serves both pair kinds and any later fee change.
/// @dev Provenance: the pool must be what a PINNED factory returns for (tokenIn, tokenOut, pair.stable()) — a
///      fake pool that lies about `stable()` cannot make a real factory return its address. PUSH model, the
///      UniV2FeeTaxSafeAdapter order: push first, read reserves after (a token that swaps on the pair inside
///      `transfer` has already moved them), price what the pair really received. Output taxes need nothing
///      here: the router measures the delivered balance and enforces minOut.
contract SolidlyPairAdapter is IAdapter, BaseAdapter {
    address[] public factories;

    error PoolNotCanonical(address pool);
    error EmptyFactoryList();
    error ZeroFactory();
    /// @notice The pair received nothing from the push (a token that eats 100 % or blocks the pair).
    error NothingReceived();
    /// @notice The pair priced the received amount at zero output.
    error ZeroOutput();

    constructor(address nullRouter_, address[] memory factories_) BaseAdapter(nullRouter_) {
        if (factories_.length == 0) revert EmptyFactoryList();
        for (uint256 i = 0; i < factories_.length; i++) {
            if (factories_[i] == address(0)) revert ZeroFactory();
            factories.push(factories_[i]);
        }
    }

    function factoriesLength() external view returns (uint256) {
        return factories.length;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pair).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        ISolidlyPair pair = ISolidlyPair(pool);
        _requireCanonical(pool, tokenIn, tokenOut, pair.stable());
        bool zeroForOne = tokenIn == pair.token0();

        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 received = IERC20BalS(tokenIn).balanceOf(pool) - reserveIn;
        if (received == 0) revert NothingReceived();

        amountOut = pair.getAmountOut(received, tokenIn);
        if (amountOut == 0) revert ZeroOutput();
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, to, "");
    }

    /// @dev Reverts unless a PINNED factory returns `pool` for (tokenA, tokenB, stable) — through `getPair` (Solidly V1,
    ///      Blackhole) or `getPool` (Velodrome / Aerodrome V2, whose factories revert on `getPair`). Both are registry
    ///      lookups on a pinned factory, so trying the second name widens nothing. A staticcall failure is a no-match,
    ///      never a veto of later factories.
    function _requireCanonical(address pool, address tokenA, address tokenB, bool stable) internal view {
        if (pool == address(0)) revert PoolNotCanonical(pool);
        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            if (_lookup(factories[i], ISolidlyFactory.getPair.selector, tokenA, tokenB, stable) == pool) return;
            if (_lookup(factories[i], ISolidlyFactory.getPool.selector, tokenA, tokenB, stable) == pool) return;
        }
        revert PoolNotCanonical(pool);
    }

    function _lookup(address factory, bytes4 selector, address tokenA, address tokenB, bool stable)
        internal
        view
        returns (address)
    {
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSelector(selector, tokenA, tokenB, stable));
        return ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }
}
