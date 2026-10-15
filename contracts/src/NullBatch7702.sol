// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

    // ── account compatibility for a delegated EOA (audit M6) ──────────────────
    // A 7702 authorization gives the EOA code, so counterparties that branch on `code.length > 0` stop
    // treating it as an EOA: Permit2's SignatureVerification (and OZ SignatureChecker) take the ERC-1271
    // path, and NFT `safeTransferFrom` calls the receiver hook. With neither implemented and no fallback
    // those calls REVERT — a user on the persistent raw-7702 path silently lost `swapPermit2`, the whole
    // Permit2 gasless flow, and every NFT receipt. Restores EOA-equivalent behaviour; still no owner, no
    // custody and no storage.

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

    /// @notice ERC-1271. The account IS the signer — under 7702 `address(this)` is the EOA whose key
    /// signed — so plain ECDSA recovery against it reproduces exactly the pre-delegation semantics.
    /// `tryRecover` returns an error instead of reverting on malleable/short signatures.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == address(this)) return ERC1271_MAGIC;
        return 0xffffffff;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }

    /// @dev ERC-165: ERC165 itself, ERC721Receiver, ERC1155Receiver — some tokens check before sending.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x150b7a02 || id == 0x4e2312e0;
    }

    /// @notice Accept native value so a native-in swap can be funded through the batch.
    receive() external payable {}

    /// @dev Permissive no-op fallback: a plain EOA accepts ANY calldata without reverting, and a
    /// delegated account must keep doing so or unrelated integrations break on an unknown selector.
    /// Safe because it does nothing — `execute` remains the only thing that can move value, and it is
    /// still gated on `msg.sender == address(this)`.
    fallback() external payable {}
}
