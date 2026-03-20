// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
contract LFJAdapter is IAdapter {
    ILBRouter public immutable ROUTER;

    constructor(address router_) {
        ROUTER = ILBRouter(router_);
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(uint256 binStep)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        uint256 binStep = abi.decode(extraData, (uint256));

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
