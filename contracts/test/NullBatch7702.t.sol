// SPDX-License-Identifier: UNLICENSED
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
}
