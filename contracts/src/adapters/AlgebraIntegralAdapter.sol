// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Algebra Integral factory registry: default pools by pair, and pools created through a custom pool deployer
///         (`createCustomPool`) by (deployer, pair). Both mappings are written for both token orderings.
interface IAlgebraIntegralFactory {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
    function customPoolByPair(address deployer, address tokenA, address tokenB) external view returns (address pool);
}

interface IAlgebraIntegralPool {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title AlgebraIntegralAdapter
/// @notice Swaps on Algebra Integral pools (pool.swap + algebraSwapCallback) across several venues on one chain —
///         written for Blackhole CL (Avalanche; pools come from CUSTOM pool deployers, so `poolByPair` is zero),
///         Hydrex Integral + QuickSwap V4 (Base) and THENA V3 (BNB). Integral plugins may change the fee per swap;
///         the pool applies it inside `swap`, so the adapter prices nothing — the router measures the delivered
///         balance and enforces minOut.
/// @dev Provenance: each pinned entry is (factory, deployer). deployer == 0 → the pool must be the factory's
///      `poolByPair` for the pool's own tokens; otherwise its `customPoolByPair(deployer, …)`. Both orderings are
///      tried. A pool no pinned entry returns is refused, so a contract that merely looks like an Algebra pool cannot
///      arm the callback gate. The callback is authenticated by a transient-storage slot holding the pool being
///      swapped (EIP-1153), set just before `swap` and cleared after. A partial fill's unspent input is swept to `to`
///      (the router), as in AlgebraAdapter.
contract AlgebraIntegralAdapter is IAdapter, BaseAdapter {
    struct Venue {
        address factory;
        address deployer;
    }

    Venue[] public venues;

    error PoolNotRegistered(address pool);
    error PairMismatch();
    error NoOutput();
    error EmptyVenueList();
    error LengthMismatch();
    error ZeroFactory();

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint256 private constant EXPECTED_POOL_SLOT = uint256(keccak256("chord.algebraIntegral.expectedPool"));

    constructor(address nullRouter_, address[] memory factories_, address[] memory deployers_) BaseAdapter(nullRouter_) {
        if (factories_.length == 0) revert EmptyVenueList();
        if (factories_.length != deployers_.length) revert LengthMismatch();
        for (uint256 i = 0; i < factories_.length; i++) {
            if (factories_[i] == address(0)) revert ZeroFactory();
            venues.push(Venue(factories_[i], deployers_[i]));
        }
    }

    function venuesLength() external view returns (uint256) {
        return venues.length;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        IAlgebraIntegralPool p = IAlgebraIntegralPool(pool);
        address token0 = p.token0();
        address token1 = p.token1();
        _requireRegistered(pool, token0, token1);

        bool zeroToOne;
        if (tokenIn == token0 && tokenOut == token1) zeroToOne = true;
        else if (tokenIn == token1 && tokenOut == token0) zeroToOne = false;
        else revert PairMismatch();

        _setExpectedPool(pool);
        (int256 amount0, int256 amount1) = p.swap(
            to,
            zeroToOne,
            int256(amountIn),
            zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        _setExpectedPool(address(0));

        int256 outDelta = zeroToOne ? amount1 : amount0;
        if (outDelta >= 0) revert NoOutput();
        amountOut = uint256(-outDelta);

        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) TransferLib.safeTransfer(tokenIn, to, leftoverIn);
    }

    /// @dev Callback from the pool being swapped: pay the positive delta in tokenIn (already held by this adapter).
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == _expectedPool(), "unauthorized callback");
        address tokenIn = abi.decode(data, (address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        TransferLib.safeTransfer(tokenIn, msg.sender, owed);
    }

    function _requireRegistered(address pool, address token0, address token1) internal view {
        uint256 n = venues.length;
        for (uint256 i = 0; i < n; i++) {
            Venue memory v = venues[i];
            if (v.deployer == address(0)) {
                if (_lookup(v.factory, abi.encodeWithSelector(IAlgebraIntegralFactory.poolByPair.selector, token0, token1)) == pool) return;
                if (_lookup(v.factory, abi.encodeWithSelector(IAlgebraIntegralFactory.poolByPair.selector, token1, token0)) == pool) return;
            } else {
                if (_lookup(v.factory, abi.encodeWithSelector(IAlgebraIntegralFactory.customPoolByPair.selector, v.deployer, token0, token1)) == pool) return;
                if (_lookup(v.factory, abi.encodeWithSelector(IAlgebraIntegralFactory.customPoolByPair.selector, v.deployer, token1, token0)) == pool) return;
            }
        }
        revert PoolNotRegistered(pool);
    }

    function _lookup(address factory, bytes memory call) private view returns (address) {
        (bool ok, bytes memory ret) = factory.staticcall(call);
        return ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _setExpectedPool(address pool) private {
        uint256 slot = EXPECTED_POOL_SLOT;
        assembly {
            tstore(slot, pool)
        }
    }

    function _expectedPool() private view returns (address pool) {
        uint256 slot = EXPECTED_POOL_SLOT;
        assembly {
            pool := tload(slot)
        }
    }
}
