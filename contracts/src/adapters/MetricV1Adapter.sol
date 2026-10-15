// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Metric OMM v1 factory — the pool registry. Same address on every chain Metric deploys to
///         (CREATE2 / CREATE3): 0x2a53833cc95548cf52c7b159110e22D3a9018f32. `isPool` selector 0x5b16ebb7.
interface IMetricV1Factory {
    function isPool(address pool) external view returns (bool);
}

/// @notice Metric OMM v1 SimpleRouter (0x02201E6f13c41506c7Bb635d7543F98826229aB7 on every chain). It pulls
///         `tokenIn` from msg.sender with transferFrom and pays `tokenOut` to `recipient`.
///         `exactInputSingle` selector 0x865f5093, read from the SDK ABI and called on Monad mainnet 2026-10-11.
interface IMetricV1SimpleRouter {
    struct ExactInputSingleParams {
        address pool;
        address tokenIn;
        address tokenOut;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        address recipient;
        uint256 deadline;
        uint128 priceLimitX64;
        bytes extensionData;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title MetricV1Adapter
/// @notice Exact-in swaps on Metric OMM **v1** pools through Metric's SimpleRouter.
/// @dev v1 is a different protocol generation from the one `MetricAdapter` serves (which Metric's own SDK now
///      calls v0): new factory, new pool bytecode, a 24-field `getImmutables`, a quoter contract, and pool
///      extensions. On Monad the v0 WMON/USDC pool held nothing on 2026-10-11 while the v1 pool held the venue's
///      whole inventory, so the two adapters are not interchangeable.
///
///      IMMUTABLE, stateless, PUSH model: the router transfers tokenIn here BEFORE calling swap(); this adapter
///      never pulls from its caller. Output is measured by balance delta and forwarded to `to`; the adapter ends
///      every swap holding neither token.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived on-chain from the pool's own token0 /
///      token1 (zeroForOne = tokenIn == token0).
///
///      H1 provenance: `pool` arrives in caller-supplied extraData and receives an approval-backed swap, so it
///      must be a real Metric pool. v1 HAS a registry view — `factory.isPool(pool)` — so the check is the
///      factory's own answer, not an immutable allowlist: a pool Metric creates tomorrow routes without a
///      redeploy, and a contract that merely answers `getImmutables()` does not pass. Entry is `onlyRouter`.
///
///      Why the SimpleRouter and not `pool.swap` + a callback: a pool may carry a swap-allowlist extension, and
///      Metric gates the ROUTER contract there, not the end user. Going through their router is the path every
///      pool accepts.
///
///      amountOutMinimum = 0 and the deadline window are venue-level no-ops: the Chord router enforces the real
///      minimum and deadline for the whole route. priceLimitX64 is the SDK's own no-bound sentinel: 0 when
///      selling token0, type(uint128).max when selling token1.
///
///      ERC-20 only: the Chord router wraps native before any ERC-20 adapter, so no receive().
contract MetricV1Adapter is IAdapter, BaseAdapter {
    /// @notice Metric OMM v1 SimpleRouter.
    IMetricV1SimpleRouter public immutable ROUTER;
    /// @notice Metric OMM v1 factory (pool registry).
    IMetricV1Factory public immutable FACTORY;

    /// @notice Venue-level deadline no-op window (the Chord router enforces the real deadline).
    uint256 private constant EXPIRY_WINDOW = 300;
    /// @dev `getImmutables()` — a static struct whose first three words are factory, token0, token1.
    bytes4 private constant GET_IMMUTABLES = 0xbcdb4dad;

    /// @notice `pool` is not registered in the Metric v1 factory.
    error NotMetricPool(address pool);
    /// @notice tokenIn / tokenOut are not this pool's two tokens.
    error PairMismatch();
    /// @notice The pool did not answer `getImmutables()` with at least factory, token0, token1.
    error BadImmutables();
    /// @notice amountIn does not fit the router's uint128.
    error AmountTooLarge();
    /// @notice The swap delivered nothing.
    error NoFill();
    error ZeroAddress();

    constructor(address nullRouter_, address router_, address factory_) BaseAdapter(nullRouter_) {
        if (router_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        ROUTER = IMetricV1SimpleRouter(router_);
        FACTORY = IMetricV1Factory(factory_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — the Metric v1 pool.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata extraData)
        external
        override
        onlyRouter
        returns (uint256 amountOut)
    {
        address pool = abi.decode(extraData, (address));
        if (!FACTORY.isPool(pool)) revert NotMetricPool(pool); // H1 provenance — see contract NatSpec.

        (address token0, address token1) = _poolTokens(pool);
        bool zeroForOne;
        if (tokenIn == token0 && tokenOut == token1) {
            zeroForOne = true;
        } else if (tokenIn == token1 && tokenOut == token0) {
            zeroForOne = false;
        } else {
            revert PairMismatch();
        }
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);
        ROUTER.exactInputSingle(
            IMetricV1SimpleRouter.ExactInputSingleParams({
                pool: pool,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0, // the Chord router's minimum for the route is the real protection
                recipient: address(this),
                deadline: block.timestamp + EXPIRY_WINDOW,
                priceLimitX64: zeroForOne ? 0 : type(uint128).max, // no-bound sentinel per direction
                extensionData: ""
            })
        );
        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut == 0) revert NoFill();
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // If the venue used less than amountIn, the remainder goes to `to` with the output (the Chord router's
        // dust sweep returns it to the user on a single hop). The adapter MUST end at zero balance.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) TransferLib.safeTransfer(tokenIn, to, leftoverIn);
    }

    /// @dev token0 / token1 from the pool's immutables. The v1 struct has 24 static fields; only words 1 and 2
    ///      are read, so the adapter does not depend on the rest of the layout.
    function _poolTokens(address pool) private view returns (address token0, address token1) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSelector(GET_IMMUTABLES));
        if (!ok || ret.length < 96) revert BadImmutables();
        (, token0, token1) = abi.decode(ret, (address, address, address));
    }
}
