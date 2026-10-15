// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RouteLib
/// @notice Route encoding/decoding for NullRouter calldata
library RouteLib {
    // TODO: Implement route encoding/decoding
    // Routes are encoded as packed bytes for gas efficiency:
    //   [adapter(20)] [tokenIn(20)] [tokenOut(20)] [amountIn(32)] [extraDataLen(2)] [extraData(var)]
}
