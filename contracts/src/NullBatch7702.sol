// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title NullBatch7702
/// @notice Minimal EIP-7702 batch-call delegate for one-signature swaps on Monad.
///
/// A user's EOA signs a 7702 authorization pointing at this contract, then sends ONE type-4
/// transaction that calls `execute([approve(router, amount), router.swap(...)])`. Because the EOA is
/// running this contract's code as its own, `msg.sender == address(this)` inside `execute` — that is
/// the ONLY caller allowed, so nobody else can drive a delegated account's `execute`. The batch turns
/// the classic approve→swap two-popup flow into a single confirmation.
///
/// Deliberately tiny and stateless: no owner, no upgrade, no token custody, no storage. It only ever
/// forwards the calls the account itself authorized in the same transaction. A failing sub-call
/// bubbles its revert reason so the wallet shows why.
contract NullBatch7702 {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    error OnlySelf();
    error CallReverted(uint256 index);

    /// @notice Execute a batch of calls from the account itself (the 7702-delegated EOA).
    /// @dev Guarded to `address(this)`: under 7702 the delegated EOA calling its own code has
    ///      `msg.sender == address(this)`. Any external caller fails here, so a delegated account
    ///      can never be driven by a third party.
    function execute(Call[] calldata calls) external payable {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 n = calls.length;
        for (uint256 i = 0; i < n; ) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                // Bubble the sub-call's revert reason if present; otherwise a typed error with index.
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 0x20), mload(ret))
                    }
                }
                revert CallReverted(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Accept native value so a native-in swap can be funded through the batch.
    receive() external payable {}
}
