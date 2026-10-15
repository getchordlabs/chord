// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface ICloberController {
    struct PermitSignature {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct SpendOrderParams {
        uint192 id;
        uint256 limitPrice;
        uint256 baseAmount;
        uint256 minQuoteAmount;
        bytes hookData;
    }

    struct ERC20PermitParams {
        address token;
        uint256 permitAmount;
        PermitSignature signature;
    }

    function spend(
        SpendOrderParams[] calldata orderParamsList,
        address[] calldata tokensToSettle,
        ERC20PermitParams[] calldata permitParamsList,
        uint64 deadline
    ) external payable;
}

/// @title CloberAdapter
/// @notice Executes swaps on Clober V2 CLOB via Controller.spend()
/// @dev H1 (2026-08-05 audit): extraData carries only a `uint192 bookId` — no caller-chosen address —
///      but swap() was world-callable, and this DEAD-but-still-approved adapter was found holding
///      1 WMON, i.e. the only concrete loss the whole H1 sweep could point at. `onlyRouter` closes
///      it. Removing this adapter from the registry (M2) remains the actual fix; the gate just means
///      the stranded dust cannot be swept by a stranger while that happens.
contract CloberAdapter is IAdapter, BaseAdapter {
    ICloberController public immutable CONTROLLER;
    address public immutable BOOK_MANAGER;

    constructor(address nullRouter_, address controller_, address bookManager_)
        BaseAdapter(nullRouter_)
    {
        require(controller_ != address(0) && bookManager_ != address(0), "CLOBER_ZERO_ADDR");
        CONTROLLER = ICloberController(controller_);
        BOOK_MANAGER = bookManager_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(uint192 bookId)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        uint192 bookId = abi.decode(extraData, (uint192));

        TransferLib.safeApprove(tokenIn, address(CONTROLLER), amountIn);
        TransferLib.safeApprove(tokenIn, BOOK_MANAGER, amountIn);

        ICloberController.SpendOrderParams[] memory orders =
            new ICloberController.SpendOrderParams[](1);
        orders[0] = ICloberController.SpendOrderParams({
            id: bookId,
            limitPrice: type(uint256).max,
            baseAmount: amountIn,
            minQuoteAmount: 0,
            hookData: ""
        });

        address[] memory tokens = new address[](2);
        tokens[0] = tokenIn;
        tokens[1] = tokenOut;

        ICloberController.ERC20PermitParams[] memory permits =
            new ICloberController.ERC20PermitParams[](0);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        CONTROLLER.spend(orders, tokens, permits, uint64(block.timestamp + 300));

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (amountOut > 0) {
            TransferLib.safeTransfer(tokenOut, to, amountOut);
        }

        TransferLib.safeApprove(tokenIn, address(CONTROLLER), 0);
        TransferLib.safeApprove(tokenIn, BOOK_MANAGER, 0);
    }
}
