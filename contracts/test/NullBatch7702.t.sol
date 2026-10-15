// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NullBatch7702} from "../src/NullBatch7702.sol";

// ROUND 12 (F9) — the delegate a user's EOA runs as its own code under EIP-7702.
//
// The entire safety of that arrangement is one line: `msg.sender != address(this) → OnlySelf`.
// If it ever weakened, ANY address could drive a delegated account's execute() and spend whatever
// the account had approved. The contract had no test file at all.

contract Sink {
    uint256 public calls;
    uint256 public received;
    bool public shouldRevert;

    function ping() external payable { calls++; received += msg.value; }
    function boom() external { revert("sink exploded"); }
}

contract NullBatch7702Test is Test {
    NullBatch7702 batch;
    Sink sink;
    address stranger = address(0xBAD);

    function setUp() public {
        batch = new NullBatch7702();
        sink = new Sink();
    }

    function _call(address to, uint256 value, bytes memory data) internal pure returns (NullBatch7702.Call memory) {
        return NullBatch7702.Call({to: to, value: value, data: data});
    }

    function test_strangerCannotDriveADelegatedAccount() public {
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](1);
        calls[0] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));

        vm.prank(stranger);
        vm.expectRevert(NullBatch7702.OnlySelf.selector);
        batch.execute(calls);
        assertEq(sink.calls(), 0, "a stranger's batch must not execute anything");
    }

    function test_notEvenTheDeployerOrContractsCanDriveIt() public {
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](1);
        calls[0] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));

        // The deployer has no special status — there is no owner by design.
        vm.expectRevert(NullBatch7702.OnlySelf.selector);
        batch.execute(calls);

        // Another contract calling in is equally rejected.
        Sink caller = new Sink();
        vm.prank(address(caller));
        vm.expectRevert(NullBatch7702.OnlySelf.selector);
        batch.execute(calls);
    }

    function test_theAccountItselfExecutesTheWholeBatchInOrder() public {
        // Under 7702 the delegated EOA runs this code, so msg.sender == address(this). prank both
        // sender and origin to reproduce that exactly.
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](2);
        calls[0] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));
        calls[1] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));

        vm.prank(address(batch));
        batch.execute(calls);
        assertEq(sink.calls(), 2, "both calls in the batch must run");
    }

    function test_nativeValueFlowsThroughToTheSubCall() public {
        // A native-in swap funds the router through the batch; the value must reach the sub-call,
        // not sit in the delegate.
        vm.deal(address(batch), 5 ether);
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](1);
        calls[0] = _call(address(sink), 2 ether, abi.encodeWithSignature("ping()"));

        vm.prank(address(batch));
        batch.execute{value: 0}(calls);
        assertEq(sink.received(), 2 ether, "value must reach the sub-call");
    }

    function test_aFailingSubCallBubblesItsReasonAndAbortsTheBatch() public {
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](3);
        calls[0] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));
        calls[1] = _call(address(sink), 0, abi.encodeWithSignature("boom()"));
        calls[2] = _call(address(sink), 0, abi.encodeWithSignature("ping()"));

        vm.prank(address(batch));
        vm.expectRevert(bytes("sink exploded")); // the wallet must see WHY, not a generic failure
        batch.execute(calls);
        // The whole transaction reverts, so the first ping is rolled back too — a half-applied
        // approve+swap batch is exactly what must never happen.
        assertEq(sink.calls(), 0, "a failed batch must leave no partial effects");
    }

    function test_anEmptyBatchIsANoOp() public {
        NullBatch7702.Call[] memory calls = new NullBatch7702.Call[](0);
        vm.prank(address(batch));
        batch.execute(calls);
        assertEq(sink.calls(), 0);
    }

    // ── M6: a delegated EOA has code, so counterparties stop treating it as an EOA ──
    // Permit2's SignatureVerification (and OZ SignatureChecker) branch to ERC-1271 the moment
    // `code.length > 0`. With no isValidSignature and no fallback the call REVERTED, so a user on the
    // persistent raw-7702 path silently lost swapPermit2, the whole Permit2 gasless flow, and every
    // NFT receipt. These pin the EOA-equivalent behaviour back in place.

    function test_isValidSignatureAcceptsTheAccountsOwnSignature() public {
        // Under 7702 the account IS the signer: etch the delegate's code at the signer's address so
        // `address(this)` inside isValidSignature is the EOA that holds the key.
        uint256 pk = 0xA11CE;
        address eoa = vm.addr(pk);
        vm.etch(eoa, address(batch).code);

        bytes32 hash = keccak256("permit2 witness digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        bytes4 magic = NullBatch7702(payable(eoa)).isValidSignature(hash, abi.encodePacked(r, s, v));
        assertEq(magic, bytes4(0x1626ba7e), "ERC-1271 magic value - Permit2 accepts the signature");
    }

    function test_isValidSignatureRejectsSomeoneElsesSignature() public {
        uint256 pk = 0xA11CE;
        address eoa = vm.addr(pk);
        vm.etch(eoa, address(batch).code);

        bytes32 hash = keccak256("permit2 witness digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBAD5), hash); // a different key
        bytes4 res = NullBatch7702(payable(eoa)).isValidSignature(hash, abi.encodePacked(r, s, v));
        assertEq(res, bytes4(0xffffffff), "a foreign signature must NOT validate");

        // Junk must fail closed, not revert-with-panic.
        res = NullBatch7702(payable(eoa)).isValidSignature(hash, hex"1234");
        assertEq(res, bytes4(0xffffffff), "a malformed signature must fail closed");
    }

    function test_nftReceiverHooksAndErc165() public view {
        assertEq(batch.onERC721Received(address(0), address(0), 1, ""), bytes4(0x150b7a02));
        assertEq(batch.onERC1155Received(address(0), address(0), 1, 1, ""), bytes4(0xf23a6e61));
        uint256[] memory ids = new uint256[](0);
        assertEq(batch.onERC1155BatchReceived(address(0), address(0), ids, ids, ""), bytes4(0xbc197c81));
        assertTrue(batch.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(batch.supportsInterface(0x150b7a02), "ERC721Receiver");
        assertTrue(batch.supportsInterface(0x4e2312e0), "ERC1155Receiver");
        assertFalse(batch.supportsInterface(0xdeadbeef));
    }

    function test_unknownCalldataSucceedsLikeAPlainEoa() public {
        // Calls to a plain EOA never revert on an unknown selector; a delegated account must not
        // start reverting or unrelated integrations break.
        (bool ok,) = address(batch).call(abi.encodeWithSignature("somethingNobodyImplements(uint256)", 1));
        assertTrue(ok, "a permissive fallback keeps EOA semantics");
    }
}
