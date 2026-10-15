// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface ICurveStableSwapNG {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @title CurveAdapterNG
/// @notice Executes swaps on Curve StableSwap-NG pools via exchange(int128,int128,...).
/// @dev The original CurveAdapter targets the TwoCrypto flavor (uint256 indices) — but the live
///      Monad pools we route (BTC 3-pool, LST 4-pool) are StableSwap-NG, whose exchange takes
///      int128 indices (different selector; verified on-chain: get_dy(int128,...) succeeds and the
///      uint256 flavor reverts on both). extraData = abi.encode(address pool, int128 i, int128 j).
///      StableSwap-NG Factory: 0x8271e06E5887FE5ba05234f5315c19f3Ec90E8aD
///
///      H1 (2026-08-05 audit): `pool` arrived in caller-supplied extraData and immediately received
///      an ERC20 approval sized to the input, from a world-callable function. Now `onlyRouter`
///      (BaseAdapter) + PROVENANCE against the factory pinned at construction: the factory must know
///      the pool (`get_n_coins` > 0 — unregistered pools return 0), and only THEN are the pool's own
///      `coins(i)/coins(j)` trustworthy enough to bind the indices to (tokenIn, tokenOut). That index
///      binding is worth having on its own: a mismatched (i, j) silently swaps the wrong pair inside
///      a multi-coin pool.
///
///      `get_n_coins` is read via low-level staticcall because Curve factory generations disagree on
///      its return arity (uint256 vs a tuple) — the FIRST word is the coin count in both, and a
///      factory that does not implement it at all fails closed here.
contract CurveAdapterNG is IAdapter, BaseAdapter {
    /// @notice Curve StableSwap-NG factory whose pools this adapter will trade — pinned at deploy.
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
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address pool, int128 i, int128 j) = abi.decode(extraData, (address, int128, int128));
        _requirePoolAndCoins(pool, i, j, tokenIn, tokenOut);

        TransferLib.safeApprove(tokenIn, pool, amountIn);
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        // minOut = 0 here: the NullRouter enforces the user's minOut on the FINAL output
        // (checks-effects pattern shared by every adapter).
        ICurveStableSwapNG(pool).exchange(i, j, amountIn, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        TransferLib.safeTransfer(tokenOut, to, amountOut);
        TransferLib.safeApprove(tokenIn, pool, 0);
    }

    /// @dev H1 provenance + index binding. See the contract NatSpec for why the order matters.
    function _requirePoolAndCoins(
        address pool,
        int128 i,
        int128 j,
        address tokenIn,
        address tokenOut
    ) internal view {
        (bool ok, bytes memory ret) =
            FACTORY.staticcall(abi.encodeWithSignature("get_n_coins(address)", pool));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) == 0) {
            revert PoolNotRegistered(pool);
        }
        if (i < 0 || j < 0) revert CoinIndexMismatch();
        if (
            ICurveStableSwapNG(pool).coins(uint256(uint128(i))) != tokenIn
                || ICurveStableSwapNG(pool).coins(uint256(uint128(j))) != tokenOut
        ) {
            revert CoinIndexMismatch();
        }
    }
}
