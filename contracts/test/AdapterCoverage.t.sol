// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title AdapterCoverage
/// @notice Round 50 — every adapter that can route money has something exercising it.
///
/// @dev Counting the references from src/ into test/ produced the finding this round exists for:
///      twelve contracts scored zero, and four of them route real money today (Uniswap V4,
///      PancakeSwap V3 via V3DeadlineAdapter, LFJ, Curve NG) while the LATER integrations —
///      Balancer, Hanji, Metric, LFJ-POE — each had their own file. The newer code got tests; the
///      older code carrying the money did not.
///
///      This is the part that keeps it from happening again: the count is re-run at test time, so
///      adapter #25 cannot ship with nothing behind it. Contracts here are immutable — the cost of
///      being wrong is a redeploy plus a registry re-approve, not a diff.
contract AdapterCoverageTest is Test {
    /// @dev Adapters deliberately without tests, each with the reason it cannot route.
    ///      Anything NOT on this list must appear somewhere in test/.
    function _isRetired(string memory name) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        return
            h == keccak256("CloberAdapter") // venue removed (dust liquidity)
            || h == keccak256("CurveAdapter") // TwoCrypto flavour; NG pools use CurveAdapterNG
            || h == keccak256("NadFunDEXAdapter") // router-based, superseded by NadFunPairAdapter
            || h == keccak256("PancakeV3Adapter") // superseded by V3DeadlineAdapter (deadline flavour)
            || h == keccak256("UniV2DirectAdapter") // Uniswap V2 dropped 2026-06-26
            || h == keccak256("OctoSwapAdapter") // venue dropped 2026-06-26
            || h == keccak256("BaseAdapter"); // abstract; covered through every concrete adapter
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev Adapters covered inside a SHARED test file rather than one of their own. Naming the file
    ///      is deliberate: it is a claim someone has to make, and the test below checks the file is
    ///      really there — so this cannot rot into a list of excuses for tests that were deleted.
    function _sharedCoverage(string memory name) internal pure returns (string memory file) {
        bytes32 h = keccak256(bytes(name));
        if (
            h == keccak256("V3DeadlineAdapter") || h == keccak256("CurveAdapterNG")
                || h == keccak256("LFJAdapter") || h == keccak256("UniswapV4Adapter")
        ) return "./test/UntestedLiveAdapters.t.sol";
        if (h == keccak256("UniV3GenericAdapter") || h == keccak256("AlgebraAdapter")) {
            return "./test/PoolProvenance.t.sol";
        }
        // The H1 hardening sweep exercises these together — the gate is the same property for all.
        if (
            h == keccak256("KuruAdapter") || h == keccak256("MentoAdapter")
                || h == keccak256("NadFunBCAdapter") || h == keccak256("NadFunPairAdapter")
                || h == keccak256("NadFunV2Adapter")
        ) return "./test/adapters/AdapterHardening.t.sol";
        return "";
    }

    function _fileExists(string memory path) internal view returns (bool) {
        try vm.readFile(path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// Scanning every test file's contents costs a billion gas in Solidity, so the check is on
    /// NAMES: an adapter earns coverage by having its own `<Name>.t.sol`, or by being declared above
    /// as living in a shared file that must itself exist.
    function test_everyLiveAdapterIsExercisedBySomeTest() public view {
        VmSafe.DirEntry[] memory adapters = vm.readDir("./src/adapters", 1);

        string memory missing = "";
        uint256 count;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i].isDir) continue;
            string memory path = adapters[i].path;
            if (!_contains(path, ".sol")) continue;

            bytes memory p = bytes(path);
            uint256 start;
            for (uint256 k = 0; k < p.length; k++) {
                if (p[k] == "/") start = k + 1;
            }
            bytes memory nameBytes = new bytes(p.length - start - 4);
            for (uint256 k = 0; k < nameBytes.length; k++) {
                nameBytes[k] = p[start + k];
            }
            string memory name = string(nameBytes);

            if (_isRetired(name)) continue;
            count++;

            // Adapter tests live in test/ or test/adapters/ — check both before calling it missing.
            if (_fileExists(string.concat("./test/", name, ".t.sol"))) continue;
            if (_fileExists(string.concat("./test/adapters/", name, ".t.sol"))) continue;
            string memory shared = _sharedCoverage(name);
            if (bytes(shared).length > 0 && _fileExists(shared)) continue;

            missing = string.concat(missing, name, " ");
        }

        assertGt(count, 10, "the scan found almost no adapters - the reader broke, not the tree");
        assertEq(
            missing,
            "",
            string.concat(
                "live adapters with no test at all: ",
                missing,
                "- give it a <Name>.t.sol, declare it in _sharedCoverage, or retire it in _isRetired"
            )
        );
    }
}
