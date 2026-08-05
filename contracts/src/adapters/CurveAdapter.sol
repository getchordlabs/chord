// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface ICurvePool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @title CurveAdapter
/// @notice Executes swaps on Curve pools via exchange()
/// @dev Works with StableSwap and TwoCrypto pools.
///      StableSwap Factory: 0x8271e06E5887FE5ba05234f5315c19f3Ec90E8aD
///      TwoCrypto Factory: 0xe7FBd704B938cB8fe26313C3464D4b7B7348c88C
///
///      ⚠️ FLAVOR TRAP: this contract calls exchange(uint256,…) = TwoCrypto. StableSwap-NG pools take
///      int128 indices and REVERT here — use CurveAdapterNG for those.
///
///      H1 (2026-08-05 audit): same treatment as CurveAdapterNG — `onlyRouter` plus factory
///      registration (`get_n_coins` > 0) and an (i, j) ↔ (tokenIn, tokenOut) binding read off the
///      now-authenticated pool. This adapter is currently NOT in the approved set (M2 recommends
///      removing it); it is hardened rather than left as a loaded gun in case volume returns.
contract CurveAdapter is IAdapter, BaseAdapter {
    /// @notice Curve factory whose pools this adapter will trade — pinned at deploy.
    address public immutable FACTORY;

    /// @notice The pinned factory does not know this pool.
    error PoolNotRegistered(address pool);
    /// @notice (i, j) do not name (tokenIn, tokenOut) in the pool's coin list.
    error CoinIndexMismatch();

    constructor(address nullRouter_, address factory_) BaseAdapter(nullRouter_) {
        require(factory_ != address(0), "CURVE_ZERO_FACTORY");
        FACTORY = factory_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool, uint256 i, uint256 j)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address pool, uint256 i, uint256 j) =
            abi.decode(extraData, (address, uint256, uint256));

        // H1 provenance: the factory must know the pool BEFORE its coins() answers are trusted.
        (bool ok, bytes memory ret) =
            FACTORY.staticcall(abi.encodeWithSignature("get_n_coins(address)", pool));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) == 0) {
            revert PoolNotRegistered(pool);
        }
        if (
            ICurvePool(pool).coins(i) != tokenIn || ICurvePool(pool).coins(j) != tokenOut
        ) {
            revert CoinIndexMismatch();
        }

        // Approve pool
        TransferLib.safeApprove(tokenIn, pool, amountIn);

        // Record output balance
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap
        ICurvePool(pool).exchange(i, j, amountIn, 0);

        // Calculate output
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        // Transfer to recipient
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Reset approval
        TransferLib.safeApprove(tokenIn, pool, 0);
    }
}
