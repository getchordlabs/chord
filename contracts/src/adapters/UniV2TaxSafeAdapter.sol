// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface IUniV2PairT {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IERC20Bal {
    function balanceOf(address) external view returns (uint256);
}

/// @title UniV2TaxSafeAdapter
/// @notice UniV2GenericAdapter for chains whose V2 tokens carry TRANSFER TAXES (Arc 5042: every
///         official-factory token measured 2026-09-16 — 401K, Big, 0xadb2…, 0x9012… — takes 1–2 % on
///         each transfer). The generic adapter prices `amountOut` off `amountIn`, but the pair only
///         receives `amountIn × (1 − tax)`, so `pair.swap` reverts `UniswapV2: K`. This one prices off
///         what the pair ACTUALLY received (balance − reserve after the push), the same rule as
///         Uniswap's `swapExactTokensForTokensSupportingFeeOnTransferTokens`. Output taxes (pair → to)
///         need nothing here: NullRouter measures the delivered balance (M1) and enforces minOut.
/// @dev Identical provenance to UniV2GenericAdapter (`_requireCanonicalPair`: pinned factories, both
///      getPair shapes, `stable` hardcoded false). Separate contract on purpose — the generic one is
///      live on RH and its source must not change (Sourcify full match).
contract UniV2TaxSafeAdapter is IAdapter, BaseAdapter {
    address[] public factories;

    error PoolNotCanonical(address pool);
    error EmptyFactoryList();
    error ZeroFactory();
    /// @notice The pair received nothing from the push (a token that eats 100 % or blocks the pair).
    error NothingReceived();

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
        _requireCanonicalPair(pool, tokenIn, tokenOut);
        IUniV2PairT pair = IUniV2PairT(pool);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool zeroForOne = tokenIn == pair.token0();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));

        // Push, then price off what actually landed (fee-on-transfer safe).
        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        uint256 received = IERC20Bal(tokenIn).balanceOf(pool) - reserveIn;
        if (received == 0) revert NothingReceived();

        uint256 inWithFee = received * 997;
        amountOut = (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);

        (uint256 amount0Out, uint256 amount1Out) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, to, "");
    }

    /// @dev `pool` must be the pair a PINNED factory returns for (tokenA, tokenB); both getPair
    ///      shapes tried, `stable` hardcoded false (a Solidly stable pair prices on x³y+y³x=k and
    ///      would be mispriced by the constant-product math above). A staticcall failure is a
    ///      no-match, never a veto of the factories after it.
    function _requireCanonicalPair(address pool, address tokenA, address tokenB) internal view {
        if (pool == address(0)) revert PoolNotCanonical(pool);
        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            address factory = factories[i];
            if (_pairIs(factory, abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB), pool)) return;
            if (_pairIs(factory, abi.encodeWithSignature("getPair(address,address,bool)", tokenA, tokenB, false), pool)) return;
        }
        revert PoolNotCanonical(pool);
    }

    function _pairIs(address factory, bytes memory callData, address pool) internal view returns (bool) {
        (bool ok, bytes memory ret) = factory.staticcall(callData);
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == pool;
    }
}
