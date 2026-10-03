// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title SwapSim — run an unsigned swap AS the taker and measure what the taker ends up with
/// @notice NEVER deployed. The api's meta-aggregator (packages/api/src/services/meta/simulate.ts) puts this
///         runtime code AT the taker's address through the `eth_call` state-override parameter and calls
///         `run(...)` from the taker. Running as the taker means `msg.sender == taker` for the router, the
///         approval is a real `approve` call (no allowance slot to guess), and the result is the taker's own
///         balance change of the output token — the one number that is the same for every aggregator, whatever
///         its router returns. A third-party transaction that reverts, pays someone else, or delivers less
///         than the minimum is seen here before anyone is asked to sign it.
/// @dev `tokenIn` / `tokenOut` = address(0) for the chain's native asset. `spender` = address(0) skips the
///      approval (native input). Approve is sent as 0 then max, return data ignored (USDT-style tokens).
///      `ret` is the target's return or revert data, cut to 256 bytes.
contract SwapSim {
    function run(address tokenIn, address tokenOut, address spender, address target, uint256 value, bytes calldata data)
        external
        returns (bool ok, uint256 received, uint256 spent, uint256 gasUsed, bytes memory ret)
    {
        if (tokenIn != address(0) && spender != address(0)) {
            (bool z,) = tokenIn.call(abi.encodeWithSelector(0x095ea7b3, spender, uint256(0)));
            (bool m,) = tokenIn.call(abi.encodeWithSelector(0x095ea7b3, spender, type(uint256).max));
            z;
            m;
        }
        uint256 out0 = _bal(tokenOut);
        uint256 in0 = _bal(tokenIn);
        uint256 g = gasleft();
        (ok, ret) = target.call{value: value}(data);
        gasUsed = g - gasleft();
        uint256 out1 = _bal(tokenOut);
        uint256 in1 = _bal(tokenIn);
        received = out1 > out0 ? out1 - out0 : 0;
        spent = in0 > in1 ? in0 - in1 : 0;
        if (ret.length > 256) {
            assembly {
                mstore(ret, 256)
            }
        }
    }

    function _bal(address token) private view returns (uint256 b) {
        if (token == address(0)) return address(this).balance;
        (bool s, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (s && r.length >= 32) b = abi.decode(r, (uint256));
    }

    /// An EOA accepts any call; routers that pay native out or ping the recipient must not see a revert here.
    receive() external payable {}

    fallback() external payable {}
}
