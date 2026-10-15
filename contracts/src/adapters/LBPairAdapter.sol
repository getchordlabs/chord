// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice Liquidity Book v2.2 pair — the subset this adapter calls.
interface ILBPairD {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getBinStep() external view returns (uint16);
    /// @dev Swaps what the pair received above its reserves; returns the packed amounts sent out
    ///      (amountX in the low 128 bits, amountY in the high 128 bits — LB PackedUint128Math).
    function swap(bool swapForY, address to) external returns (bytes32 amountsOut);
}

/// @notice Liquidity Book v2.2 factory — the pair registry used for provenance.
interface ILBFactoryD {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    function getLBPairInformation(address tokenX, address tokenY, uint256 binStep)
        external
        view
        returns (LBPairInformation memory);
}

/// @title LBPairAdapter
/// @notice Swaps directly on a Liquidity Book v2.2 pair (push the input, `pair.swap(swapForY, to)`), with no venue
///         router in between. Written for Pharaoh DLMM on Avalanche (factory 0xEb480050…, LB v2.2 pairs as 97-byte
///         immutable clones): its WAVAX/USDC bin-step-5 pair carried ~$80 M/day on 2026-10-02, and LFJAdapter cannot
///         reach it because it trades through LFJ's own LBRouter and factory.
/// @dev Provenance: the pair must be what a PINNED factory returns for (tokenX, tokenY, binStep) read from the pair,
///      the swap tokens must be exactly that pair's two tokens, and a pair the factory flags `ignoredForRouting` is
///      refused. A fake pair cannot make a real factory return its address. The pair prices the trade itself (bins
///      walked inside `swap`, fee included), so the adapter quotes nothing; the router measures the delivered balance
///      and enforces minOut. The input is pushed first and the pair swaps what it actually received (balance minus
///      reserves), so a taxed input is priced on the amount that arrived.
contract LBPairAdapter is IAdapter, BaseAdapter {
    address[] public factories;

    error PairNotCanonical(address pair);
    error TokenMismatch();
    error EmptyFactoryList();
    error ZeroFactory();
    /// @notice The pair sent nothing out.
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
        address pairAddr = abi.decode(extraData, (address));
        ILBPairD pair = ILBPairD(pairAddr);
        address tokenX = pair.getTokenX();
        address tokenY = pair.getTokenY();
        bool swapForY;
        if (tokenIn == tokenX && tokenOut == tokenY) swapForY = true;
        else if (tokenIn == tokenY && tokenOut == tokenX) swapForY = false;
        else revert TokenMismatch();
        _requireCanonical(pairAddr, tokenX, tokenY, pair.getBinStep());

        TransferLib.safeTransfer(tokenIn, pairAddr, amountIn);
        bytes32 packed = pair.swap(swapForY, to);
        amountOut = swapForY ? uint256(packed) >> 128 : uint256(uint128(uint256(packed)));
        if (amountOut == 0) revert ZeroOutput();
    }

    /// @dev Reverts unless a pinned factory returns `pair` for (tokenX, tokenY, binStep) and does not flag it
    ///      ignoredForRouting. A staticcall failure is a no-match, never a veto of later factories.
    function _requireCanonical(address pair, address tokenX, address tokenY, uint16 binStep) internal view {
        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            (bool ok, bytes memory ret) = factories[i].staticcall(
                abi.encodeWithSelector(ILBFactoryD.getLBPairInformation.selector, tokenX, tokenY, uint256(binStep))
            );
            if (!ok || ret.length < 128) continue;
            ILBFactoryD.LBPairInformation memory info = abi.decode(ret, (ILBFactoryD.LBPairInformation));
            if (info.LBPair == pair && !info.ignoredForRouting) return;
        }
        revert PairNotCanonical(pair);
    }
}
