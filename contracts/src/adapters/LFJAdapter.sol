// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice LFJ Liquidity Book factory — the venue's pair registry. Returns a zero `LBPair` when no
///         pair exists for (tokenX, tokenY, binStep).
interface ILBFactory {
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

interface ILBRouter {
    enum Version { V1, V2, V2_1, V2_2 }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        IERC20[] tokenPath;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/// @title LFJAdapter
/// @notice Executes swaps on LFJ (Trader Joe) Liquidity Book v2.2
/// @dev LBRouter: 0x18556DA13313f3532c54711497A8FedAC273220E
///      LBFactory: 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c
///
///      H1 (2026-08-05 audit): extraData carries only a `uint256 binStep`, and the destination is the
///      IMMUTABLE LBRouter — the gap was the world-callable entrypoint (`onlyRouter` now). Provenance
///      is a genuine registry lookup anyway: LBFactory must know a pair for (tokenIn, tokenOut,
///      binStep), so a bogus bin step fails here instead of deep inside the venue router.
contract LFJAdapter is IAdapter, BaseAdapter {
    ILBRouter public immutable ROUTER;
    /// @notice LFJ LBFactory — the pair registry, pinned at deploy.
    ILBFactory public immutable FACTORY;

    /// @notice No LB pair exists for (tokenIn, tokenOut, binStep) on the pinned factory.
    error PairNotRegistered(uint256 binStep);

    constructor(address nullRouter_, address router_, address factory_) BaseAdapter(nullRouter_) {
        require(router_ != address(0) && factory_ != address(0), "LFJ_ZERO_ADDR");
        ROUTER = ILBRouter(router_);
        FACTORY = ILBFactory(factory_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(uint256 binStep)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        uint256 binStep = abi.decode(extraData, (uint256));
        // H1 provenance: the factory's registry, not the caller's word, decides the pair exists.
        // getLBPairInformation is symmetric in (tokenX, tokenY) on LBFactory.
        if (FACTORY.getLBPairInformation(tokenIn, tokenOut, binStep).LBPair == address(0)) {
            revert PairNotRegistered(binStep);
        }

        TransferLib.safeApprove(tokenIn, address(ROUTER), amountIn);

        // Build path
        uint256[] memory binSteps = new uint256[](1);
        binSteps[0] = binStep;

        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        versions[0] = ILBRouter.Version.V2_2;

        IERC20[] memory tokenPath = new IERC20[](2);
        tokenPath[0] = IERC20(tokenIn);
        tokenPath[1] = IERC20(tokenOut);

        ILBRouter.Path memory path = ILBRouter.Path({
            pairBinSteps: binSteps,
            versions: versions,
            tokenPath: tokenPath
        });

        amountOut = ROUTER.swapExactTokensForTokens(
            amountIn, 0, path, to, block.timestamp + 300
        );

        TransferLib.safeApprove(tokenIn, address(ROUTER), 0);
    }
}
