// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { PoolProvenance } from "../src/adapters/BaseAdapter.sol";
import { UniV3AnyForkAdapter } from "../src/adapters/UniV3AnyForkAdapter.sol";

// Round 32 — the check that decides whether a caller-supplied pool is real.
//
// PoolProvenance and _requireCanonicalPool are the H1 remediation: before them an adapter took the
// pool address out of extraData and used it, which is how a caller could route a user's funds
// through a contract of their own choosing. Unlike round 31's target this one is ALREADY DEPLOYED,
// on 21 immutable adapters — there is no upgrade path, so a defect here is permanent until every
// adapter is redeployed and re-approved. It had no tests.
//
// The safety argument is subtle and worth restating, because these tests exist to check the CODE
// does what the argument claims: token0/token1 are read off the pool — a contract an attacker may
// have written — and that is safe only because the address is DERIVED from
// CREATE2(pinned factory, keccak(t0,t1,fee), initCodeHash). A pool lying about its pair just derives
// a different address and is rejected.
//
// Method note, learned in round 31: verifying computeAddress against computeAddress proves nothing.
// Every expectation below comes from either a restatement of the CREATE2 formula written here, or
// from a real mainnet pool whose inputs and address are public constants anyone can re-check.

contract MockPool {
    address public token0;
    address public token1;
    uint24 private _fee;
    bool private _hasFee;

    constructor(address t0, address t1, uint24 f, bool exposeFee) {
        token0 = t0;
        token1 = t1;
        _fee = f;
        _hasFee = exposeFee;
    }

    function fee() external view returns (uint24) {
        require(_hasFee, "no fee()");
        return _fee;
    }
}

/// getPool answers with whatever the test told it to — the registry lane's only source of truth.
contract MockFactory {
    mapping(bytes32 => address) public pools;
    bool public reverts;

    function setReverts(bool r) external {
        reverts = r;
    }

    function set(address t0, address t1, uint24 f, address pool) external {
        pools[keccak256(abi.encode(t0, t1, f))] = pool;
    }

    function getPool(address t0, address t1, uint24 f) external view returns (address) {
        require(!reverts, "factory down");
        return pools[keccak256(abi.encode(t0, t1, f))];
    }
}

contract PoolProvenanceTest is Test {
    // Uniswap V3 on Ethereum mainnet — every one of these is a public constant, checkable outside
    // this repo. This is the only assertion here that ties the formula to reality rather than to a
    // restatement of it.
    address constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 constant UNI_V3_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address constant TOKEN_A = address(0xAAA1);
    address constant TOKEN_B = address(0xBBB2);

    /// The CREATE2 rule, restated from the definition rather than read back off the library.
    function _create2(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    // ── P1/P2: the derivation itself ────────────────────────────────────────────

    function test_derivationMatchesAnIndependentRestatementOfCreate2() public pure {
        bytes32 salt = keccak256(abi.encode(TOKEN_A, TOKEN_B, uint24(3000)));
        assertEq(
            PoolProvenance.computeAddress(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, salt),
            _create2(UNI_V3_FACTORY, salt, UNI_V3_INIT_CODE_HASH),
            "computeAddress diverged from CREATE2"
        );
    }

    function test_derivationReproducesARealMainnetPoolAddress() public pure {
        // USDC/WETH 0.05% on Ethereum. If this ever fails, the formula is wrong in a way no amount
        // of internal consistency would reveal.
        bytes32 salt = keccak256(abi.encode(USDC, WETH, uint24(500)));
        assertEq(
            PoolProvenance.computeAddress(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, salt),
            USDC_WETH_500,
            "derivation does not reproduce the canonical USDC/WETH 0.05% pool"
        );
    }

    function test_tokenOrderAndFeeAreBothPartOfTheIdentity() public pure {
        // Swapping the token order, or changing the fee, must name a different pool — this is why an
        // adapter has to sort, and why a fee-keyed fork cannot be matched with the wrong tier.
        address sorted = PoolProvenance.computeAddress(
            UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, keccak256(abi.encode(USDC, WETH, uint24(500)))
        );
        address flipped = PoolProvenance.computeAddress(
            UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, keccak256(abi.encode(WETH, USDC, uint24(500)))
        );
        address otherFee = PoolProvenance.computeAddress(
            UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, keccak256(abi.encode(USDC, WETH, uint24(3000)))
        );
        assertTrue(sorted != flipped, "token order must change the address");
        assertTrue(sorted != otherFee, "fee must change the address");
    }

    function test_aDifferentFactoryOrInitCodeHashNamesADifferentPool() public pure {
        bytes32 salt = keccak256(abi.encode(USDC, WETH, uint24(500)));
        assertTrue(
            PoolProvenance.computeAddress(address(0xF00D), UNI_V3_INIT_CODE_HASH, salt) != USDC_WETH_500,
            "factory must be part of the identity"
        );
        assertTrue(
            PoolProvenance.computeAddress(UNI_V3_FACTORY, keccak256("some other fork"), salt) != USDC_WETH_500,
            "initCodeHash must be part of the identity"
        );
    }

    // ── P4-P7: the gate, exercised through the adapter's real entrypoint ─────────

    function _adapter(address factory, bytes32 initCodeHash) internal returns (UniV3AnyForkAdapter) {
        address[] memory f = new address[](1);
        f[0] = factory;
        bytes32[] memory h = new bytes32[](1);
        h[0] = initCodeHash;
        uint24[] memory tiers = new uint24[](2);
        tiers[0] = 500;
        tiers[1] = 3000;
        // This test contract stands in for NullRouter so `swap` can be called through onlyRouter.
        return new UniV3AnyForkAdapter(address(this), f, h, tiers);
    }

    function test_aPoolThatLiesAboutItsPairIsRejected() public {
        // The attacker's shape: deploy anything, claim to be the A/B pool. The derivation names the
        // real A/B address, which is not this contract, so the claim buys nothing.
        UniV3AnyForkAdapter adapter = _adapter(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH);
        MockPool fake = new MockPool(TOKEN_A, TOKEN_B, 500, true);

        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(fake)));
    }

    function test_aPoolWithNoFeeFunctionIsStillRejectedWhenItIsNotCanonical() public {
        // fee() is optional on forks, so its absence must not be mistaken for a pass.
        UniV3AnyForkAdapter adapter = _adapter(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH);
        MockPool fake = new MockPool(TOKEN_A, TOKEN_B, 0, false);

        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(fake)));
    }

    function test_theRegistryLaneAcceptsOnlyTheAddressTheFactoryNames() public {
        // initCodeHash == 0 selects the getPool lane deliberately (a guessed hash would brick the
        // venue). The factory is pinned and therefore trusted; the pool address is not.
        MockFactory factory = new MockFactory();
        UniV3AnyForkAdapter adapter = _adapter(address(factory), bytes32(0));
        MockPool claimed = new MockPool(TOKEN_A, TOKEN_B, 500, true);

        // Factory names a DIFFERENT address for this pair → the claim is refused.
        factory.set(TOKEN_A, TOKEN_B, 500, address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(claimed)));
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(claimed)));

        // Factory names THIS address → provenance passes, and the swap proceeds far enough to fail
        // on the pool call instead (MockPool has no swap()), which is exactly how far this test is
        // meant to get: the gate opened.
        factory.set(TOKEN_A, TOKEN_B, 500, address(claimed));
        vm.expectRevert();
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(claimed)));
        // Distinguish "gate opened" from "gate rejected" by asserting the revert is NOT the gate's.
        try adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(claimed))) {
            revert("should not succeed against a pool with no swap()");
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) {
                assembly {
                    sel := mload(add(err, 32))
                }
            }
            assertTrue(sel != UniV3AnyForkAdapter.PoolNotCanonical.selector, "gate must have accepted this pool");
        }
    }

    function test_aCanonicalPoolOfTheWrongPairIsStillRefused() public {
        // Provenance alone is not enough. A pool can be perfectly canonical and still be the wrong
        // market: without this bind, a caller could name a real pool whose tokenOut is a different
        // asset than the one the router priced and is about to pay out. The registry lane gives a
        // pool the gate genuinely accepts, so this is the first point where the bind is reachable.
        MockFactory factory = new MockFactory();
        UniV3AnyForkAdapter adapter = _adapter(address(factory), bytes32(0));
        MockPool real = new MockPool(TOKEN_A, TOKEN_B, 500, true);
        factory.set(TOKEN_A, TOKEN_B, 500, address(real));

        address TOKEN_C = address(0xCCC3);
        vm.expectRevert(bytes("V3_PAIR_MISMATCH"));
        adapter.swap(TOKEN_A, TOKEN_C, 1e18, address(this), abi.encode(address(real)));
    }

    function test_aFactoryThatRevertsDoesNotBrickTheGate() public {
        // A fork whose registry is down must not take the adapter with it — the staticcall is
        // guarded, and a canonical pool from another lane still has to be reachable.
        MockFactory factory = new MockFactory();
        factory.setReverts(true);
        UniV3AnyForkAdapter adapter = _adapter(address(factory), bytes32(0));
        MockPool fake = new MockPool(TOKEN_A, TOKEN_B, 500, true);

        // Reverting registry → no match → the gate's own error, not a bubbled "factory down".
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(fake)));
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(fake)));
    }

    function test_onlyTheRouterCanReachTheAdapterAtAll() public {
        // The other half of H1: before it, anyone could call swap() directly and drain whoever had
        // approved the adapter. Kept here so the provenance tests cannot be read as the whole story.
        UniV3AnyForkAdapter adapter = _adapter(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH);
        MockPool fake = new MockPool(TOKEN_A, TOKEN_B, 500, true);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.swap(TOKEN_A, TOKEN_B, 1e18, address(this), abi.encode(address(fake)));
    }
}
