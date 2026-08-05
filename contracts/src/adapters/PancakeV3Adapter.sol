// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter, PoolProvenance} from "./BaseAdapter.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title PancakeV3Adapter
/// @notice Executes swaps on PancakeSwap V3 / Uniswap V3 via SwapRouter02 on Monad
/// @dev Simple ERC20-to-ERC20 swaps. No native MON handling needed — Router wraps/unwraps.
///
/// SwapRouter02: 0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900
/// Factory:      0x204faca1764b154221e35c0d20abb3c525710498
/// QuoterV2:     0x661e93cca42afacb172121ef892830ca3b70f08d
///
/// Pools verified (WMON/USDC):
///   fee=500:   0x5Bc39A29EA5d8315263EC8939d6AD393dEbC34E9
///   fee=3000:  0x659bD0BC4167BA25c62E05656F78043E7eD4a9da
///   fee=10000: 0xC33e9E441e6f4E74CdB34f878bE51189C9CB00D8
///
/// H1 (2026-08-05 audit): extraData here carries only a `uint24 fee` — no caller-chosen address ever
/// reaches a transfer, and the destination is the IMMUTABLE SwapRouter02, which derives the pool from
/// its own factory. The gap was the entrypoint: swap() was world-callable, so anyone could push this
/// adapter's between-transaction balance through it. `onlyRouter` closes that. The CREATE2 derivation
/// below is defence-in-depth on top: it proves the (tokenIn, tokenOut, fee) triple names a REAL,
/// DEPLOYED pool of the factory pinned at construction, so a bogus fee tier fails here with a clear
/// error instead of somewhere inside the venue router.
contract PancakeV3Adapter is IAdapter, BaseAdapter {
    ISwapRouter02 public immutable ROUTER;
    /// @notice V3 factory this adapter's router settles against — pinned at deploy.
    address public immutable FACTORY;
    /// @notice keccak256 of the fork's pool creation code. DIFFERS per fork → constructor arg, never
    ///         a hardcoded guess (a wrong value reverts every swap; the mandatory both-ways mainnet
    ///         verification is what catches it). Pass ZERO to use the factory's own `getPool` registry
    ///         instead — equally authoritative (the factory is pinned either way) and the honest
    ///         option when a fork's creation-code hash cannot be verified.
    bytes32 public immutable POOL_INIT_CODE_HASH;

    /// @notice The (tokenIn, tokenOut, fee) triple does not name a deployed pool of FACTORY.
    error PoolNotCanonical(address derivedPool);

    constructor(address nullRouter_, address router_, address factory_, bytes32 poolInitCodeHash_)
        BaseAdapter(nullRouter_)
    {
        require(router_ != address(0) && factory_ != address(0), "V3_ZERO_ADDR");
        ROUTER = ISwapRouter02(router_);
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

        // Approve router
        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);

        // Execute swap — tokens go directly to recipient
        amountOut = ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: to,
                amountIn: amountIn,
                amountOutMinimum: 0, // Router handles slippage
                sqrtPriceLimitX96: 0
            })
        );

        // Reset approval
        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);

        // M5: SwapRouter02 pulls only what the pool consumed; a pool that terminates early leaves the
        // remainder on this IMMUTABLE, OWNERLESS adapter with no rescue. Forward it to `to`
        // (= NullRouter, which dust-sweeps it back to the user).
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @dev H1 provenance: the (token0, token1, fee) triple must name a real pool of the pinned
    ///      FACTORY — either by CREATE2 derivation landing on deployed code, or by the factory's own
    ///      `getPool` registry when no init-code hash was pinned. Tokens are sorted the way every V3
    ///      factory sorts them.
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
