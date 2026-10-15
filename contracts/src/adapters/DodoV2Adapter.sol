// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice A DODO V2 pool (DPP / DPP Advanced — market-maker private pools; the same trader interface on DSP and DVM).
///         Selectors read off the Avalanche DPP Advanced template 0xa7b9c3a1… on 2026-10-14: sellBase 0xbd6015b4,
///         sellQuote 0xdd93f59a, querySellBase 0x79a04876, querySellQuote 0x66410a21, _BASE_TOKEN_ 0x4a248d2a,
///         _QUOTE_TOKEN_ 0xd4b97046.
interface IDodoV2Pool {
    function _BASE_TOKEN_() external view returns (address);
    function _QUOTE_TOKEN_() external view returns (address);
    /// @dev PUSH model: the base sent in is `balance − reserve`; pays `to`.
    function sellBase(address to) external returns (uint256 receiveQuoteAmount);
    function sellQuote(address to) external returns (uint256 receiveBaseAmount);
}

/// @notice DODO V2 factory registry (DPPFactory / DSPFactory / DVMFactory): pools by (base, quote), in that order.
interface IDodoV2Factory {
    function getDODOPool(address baseToken, address quoteToken) external view returns (address[] memory machines);
}

/// @title DodoV2Adapter
/// @notice Exact-in swaps on DODO V2 pools — chiefly DPP Advanced, the private pools market makers run and re-price every
///         block (Avalanche WETH.e/USDC 0xb300709b…, Arbitrum WETH/USDC 0x1666ea6e…, both from the chain's DPPFactory).
/// @dev IMMUTABLE, stateless, PUSH model: the router transfers tokenIn here BEFORE calling swap(); the adapter hands it to
///      the pool (DODO V2 pools take input by transfer-then-call: the input is `balance − reserve`), calls sellBase /
///      sellQuote with itself as the recipient, and forwards the measured output to `to`. Ends every swap holding nothing.
///
///      extraData = abi.encode(address pool). H1 provenance: the pool must be listed by one of the factories pinned at
///      construction under its OWN (base, quote) — `factory.getDODOPool(base, quote)` contains it. A contract that merely
///      answers `_BASE_TOKEN_()` is refused. Entry is `onlyRouter`.
///
///      The pool prices with `tx.origin`'s fee rate (DODO V2's `querySellBase(tx.origin, …)`); the engine quotes with
///      `querySell*` for an ordinary address, and the Chord router enforces the route's minimum.
///
///      ERC-20 only: the Chord router wraps native before any ERC-20 adapter, so no receive().
contract DodoV2Adapter is IAdapter, BaseAdapter {
    /// @notice Pinned registries (unused slots are zero). Three covers DPP + DSP + DVM on one chain.
    address public immutable FACTORY0;
    address public immutable FACTORY1;
    address public immutable FACTORY2;

    /// @notice `pool` is not listed by any pinned factory under its own (base, quote).
    error NotDodoPool(address pool);
    /// @notice tokenIn / tokenOut are not this pool's base and quote.
    error PairMismatch();
    /// @notice The swap delivered nothing.
    error NoFill();
    error ZeroAddress();
    error TooManyFactories();

    constructor(address nullRouter_, address[] memory factories_) BaseAdapter(nullRouter_) {
        if (factories_.length == 0) revert ZeroAddress();
        if (factories_.length > 3) revert TooManyFactories();
        for (uint256 i = 0; i < factories_.length; i++) {
            if (factories_[i] == address(0)) revert ZeroAddress();
        }
        FACTORY0 = factories_[0];
        FACTORY1 = factories_.length > 1 ? factories_[1] : address(0);
        FACTORY2 = factories_.length > 2 ? factories_[2] : address(0);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — a DODO V2 pool listed by a pinned factory.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata extraData)
        external
        override
        onlyRouter
        returns (uint256 amountOut)
    {
        address pool = abi.decode(extraData, (address));
        address base = IDodoV2Pool(pool)._BASE_TOKEN_();
        address quote = IDodoV2Pool(pool)._QUOTE_TOKEN_();
        bool sellBase;
        if (tokenIn == base && tokenOut == quote) {
            sellBase = true;
        } else if (tokenIn == quote && tokenOut == base) {
            sellBase = false;
        } else {
            revert PairMismatch();
        }
        if (!_listed(pool, base, quote)) revert NotDodoPool(pool); // H1 provenance — see contract NatSpec.

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TransferLib.safeTransfer(tokenIn, pool, amountIn);
        if (sellBase) {
            IDodoV2Pool(pool).sellBase(address(this));
        } else {
            IDodoV2Pool(pool).sellQuote(address(this));
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut == 0) revert NoFill();
        TransferLib.safeTransfer(tokenOut, to, amountOut);
    }

    function _listed(address pool, address base, address quote) private view returns (bool) {
        address[3] memory fs = [FACTORY0, FACTORY1, FACTORY2];
        for (uint256 i = 0; i < 3; i++) {
            if (fs[i] == address(0)) continue;
            address[] memory pools = IDodoV2Factory(fs[i]).getDODOPool(base, quote);
            for (uint256 j = 0; j < pools.length; j++) {
                if (pools[j] == pool) return true;
            }
        }
        return false;
    }
}
