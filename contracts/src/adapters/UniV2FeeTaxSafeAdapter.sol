// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface IUniV2PairF {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IERC20BalF {
    function balanceOf(address) external view returns (uint256);
}

/// @title UniV2FeeTaxSafeAdapter
/// @notice `UniV2TaxSafeAdapter` for V2 forks whose swap fee is NOT 0.3 % — written for BNB Chain (56), where
///         the dominant V2 venue, PancakeSwap V2 (factory 0xcA143Ce3…, ~$1.4B/24h ex-wash, 2026-09-30), charges
///         **0.25 %** (router `getAmountOut` uses 9975/10000). The TaxSafe adapter hardcodes 997/1000, so on a
///         PCS V2 pair it pays out 5 bps less than the pair allows. Two differences, nothing else:
///           1. POOL FEE PER FACTORY — `feeBps[i]` is the fee of `factories[i]` (25 = PCS V2, 30 = canonical),
///              pinned at construction and chosen by the factory provenance already proves. A fee set BELOW the
///              pair's real fee makes its K check revert (fails closed); set above, the user is under-paid.
///           2. RESERVES READ AFTER THE PUSH — Uniswap's own `_swapSupportingFeeOnTransferTokens` order. BNB tax
///              tokens commonly "swap-and-liquify" inside `transfer` when the sell lands on the pair: the token
///              contract itself swaps (and/or adds liquidity) on the SAME pair before crediting our amount, which
///              moves the reserves. Reading them first (as TaxSafe does) then prices against stale reserves and
///              the pair reverts `UniswapV2: K` — test/adapters/UniV2FeeTaxSafeAdapter.t.sol reproduces it.
/// @dev Separate contract on purpose: UniV2TaxSafeAdapter is live on Arc (Sourcify exact_match) and its source
///      must not change. Provenance is identical (pinned factories, both getPair shapes, `stable` hardcoded
///      false — a Solidly stable pair prices on x³y+y³x=k). PUSH model; output taxes need nothing here because
///      NullRouter measures the delivered balance (M1) and enforces minOut. Per-PAIR fee forks (Biswap,
///      Nomiswap) cannot be expressed per factory and must not be pinned.
contract UniV2FeeTaxSafeAdapter is IAdapter, BaseAdapter {
    uint256 internal constant FEE_DENOMINATOR = 10_000;
    /// @notice Highest per-factory fee accepted at construction (1 %) — a deploy-script typo guard.
    uint256 public constant MAX_FEE_BPS = 100;

    address[] public factories;
    /// @notice Pool swap fee of `factories[i]`, in basis points (PancakeSwap V2 = 25, Uniswap V2 = 30).
    uint16[] public feeBps;

    error PoolNotCanonical(address pool);
    error EmptyFactoryList();
    error ZeroFactory();
    error FeeListMismatch();
    error FeeTooHigh(uint256 feeBps);
    /// @notice The pair received nothing from the push (a token that eats 100 % or blocks the pair).
    error NothingReceived();

    constructor(address nullRouter_, address[] memory factories_, uint16[] memory feeBps_) BaseAdapter(nullRouter_) {
        if (factories_.length == 0) revert EmptyFactoryList();
        if (factories_.length != feeBps_.length) revert FeeListMismatch();
        for (uint256 i = 0; i < factories_.length; i++) {
            if (factories_[i] == address(0)) revert ZeroFactory();
            if (feeBps_[i] > MAX_FEE_BPS) revert FeeTooHigh(feeBps_[i]);
            factories.push(factories_[i]);
            feeBps.push(feeBps_[i]);
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
        uint256 fee = feeBps[_canonicalFactoryIndex(pool, tokenIn, tokenOut)];
        IUniV2PairF pair = IUniV2PairF(pool);
        bool zeroForOne = tokenIn == pair.token0();

        // Push FIRST, then read reserves: whatever the token did to this pair inside `transfer` is in them.
        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 received = IERC20BalF(tokenIn).balanceOf(pool) - reserveIn;
        if (received == 0) revert NothingReceived();

        uint256 inWithFee = received * (FEE_DENOMINATOR - fee);
        amountOut = (inWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + inWithFee);

        (uint256 amount0Out, uint256 amount1Out) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, to, "");
    }

    /// @dev Index of the PINNED factory that returns `pool` for (tokenA, tokenB); both getPair shapes tried,
    ///      `stable` hardcoded false. A staticcall failure is a no-match, never a veto of later factories.
    function _canonicalFactoryIndex(address pool, address tokenA, address tokenB) internal view returns (uint256) {
        if (pool == address(0)) revert PoolNotCanonical(pool);
        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            address factory = factories[i];
            if (_pairIs(factory, abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB), pool)) return i;
            if (_pairIs(factory, abi.encodeWithSignature("getPair(address,address,bool)", tokenA, tokenB, false), pool)) {
                return i;
            }
        }
        revert PoolNotCanonical(pool);
    }

    function _pairIs(address factory, bytes memory callData, address pool) internal view returns (bool) {
        (bool ok, bytes memory ret) = factory.staticcall(callData);
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == pool;
    }
}
