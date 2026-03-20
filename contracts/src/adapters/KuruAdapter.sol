// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IKuruRouter {
    function anyToAnySwap(
        address[] calldata markets,
        bool[] calldata isBuy,
        bool[] calldata nativeSend,
        address debitToken,
        address creditToken,
        uint256 amount,
        uint256 minAmountOut
    ) external payable;
}

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title KuruAdapter
/// @notice Executes swaps on Kuru CLOB via Router.anyToAnySwap()
contract KuruAdapter is IAdapter {
    IKuruRouter public immutable KURU_ROUTER;
    address public immutable WMON;

    constructor(address kuruRouter_, address wmon_) {
        KURU_ROUTER = IKuruRouter(kuruRouter_);
        WMON = wmon_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address market, bool isBuy, bool baseIsNative)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        (address market, bool isBuy, bool baseIsNative) =
            abi.decode(extraData, (address, bool, bool));

        address[] memory markets = new address[](1);
        markets[0] = market;
        bool[] memory isBuyArr = new bool[](1);
        isBuyArr[0] = isBuy;
        bool[] memory nativeSendArr = new bool[](1);

        if (baseIsNative && !isBuy) {
            // Sell native MON → get quote token
            nativeSendArr[0] = true;
            IWMON(WMON).withdraw(amountIn);
            uint256 before = IERC20(tokenOut).balanceOf(address(this));
            KURU_ROUTER.anyToAnySwap{value: amountIn}(
                markets, isBuyArr, nativeSendArr,
                address(0), tokenOut, amountIn, 0
            );
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
            TransferLib.safeTransfer(tokenOut, to, amountOut);
        } else if (baseIsNative && isBuy) {
            // Buy native MON with quote token
            nativeSendArr[0] = false;
            TransferLib.safeApprove(tokenIn, address(KURU_ROUTER), amountIn);
            uint256 before = address(this).balance;
            KURU_ROUTER.anyToAnySwap(
                markets, isBuyArr, nativeSendArr,
                tokenIn, address(0), amountIn, 0
            );
            amountOut = address(this).balance - before;
            IWMON(WMON).deposit{value: amountOut}();
            TransferLib.safeTransfer(WMON, to, amountOut);
            TransferLib.safeApprove(tokenIn, address(KURU_ROUTER), 0);
        } else {
            // ERC20 to ERC20
            nativeSendArr[0] = false;
            TransferLib.safeApprove(tokenIn, address(KURU_ROUTER), amountIn);
            uint256 before = IERC20(tokenOut).balanceOf(address(this));
            KURU_ROUTER.anyToAnySwap(
                markets, isBuyArr, nativeSendArr,
                tokenIn, tokenOut, amountIn, 0
            );
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
            TransferLib.safeTransfer(tokenOut, to, amountOut);
            TransferLib.safeApprove(tokenIn, address(KURU_ROUTER), 0);
        }
    }

    receive() external payable {}
}
