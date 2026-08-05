// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV3AnyForkAdapter} from "../../src/adapters/UniV3AnyForkAdapter.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";

/// A V3-style pool that answers token0/token1 plus ONE of the two registry keys.
/// `spacing == 0` means "no tickSpacing() getter" (the plain Uniswap-fork shape).
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 private _fee;
    int24 private _spacing;

    constructor(address t0, address t1, uint24 fee_, int24 spacing_) {
        token0 = t0;
        token1 = t1;
        _fee = fee_;
        _spacing = spacing_;
    }

    function fee() external view returns (uint24) {
        require(_fee != 0, "no fee getter");
        return _fee;
    }

    function tickSpacing() external view returns (int24) {
        require(_spacing != 0, "no tickSpacing getter");
        return _spacing;
    }

    /// @dev Reverts with a unique sentinel. Reaching it proves provenance ACCEPTED the pool —
    ///      the alternative to try/catch gymnastics, and it fails loudly if the check is deleted.
    error ReachedPoolSwap();

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert ReachedPoolSwap();
    }
}

/// Uniswap-lineage factory: registry keyed on (token0, token1, uint24 fee).
contract MockFeeFactory {
    mapping(bytes32 => address) private pools;

    function set(address t0, address t1, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address t0, address t1, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

/// Velodrome/Slipstream lineage: registry keyed on (token0, token1, int24 tickSpacing).
/// This is the shape up_v3 / ramses_v3 / graildex_v3 use on Robinhood 4663, and the ONLY
/// shape they answer — `getPool(…,uint24)` and `poolByPair` both revert on them.
contract MockTickSpacingFactory {
    mapping(bytes32 => address) private pools;

    function set(address t0, address t1, int24 spacing, address pool) external {
        pools[keccak256(abi.encode(t0, t1, spacing))] = pool;
    }

    function getPool(address t0, address t1, int24 spacing) external view returns (address) {
        return pools[keccak256(abi.encode(t0, t1, spacing))];
    }
}

/// @notice Provenance-lane coverage for `UniV3AnyForkAdapter`.
/// @dev These assert the SECURITY CONTROL, not the happy path — every test is written so that
///      deleting `_requireCanonicalPool` (or any single lane of it) turns a passing test red. The
///      swap path itself is unchanged from UniV3GenericAdapter and is covered by that contract's
///      own fork tests; duplicating them here would test the pool, not this contract's addition.
contract UniV3AnyForkAdapterTest is Test {
    address constant ROUTER = address(0x9001);
    address constant T0 = address(0xA11CE);
    address constant T1 = address(0xB0B);

    MockFeeFactory feeFactory;
    MockTickSpacingFactory tsFactory;
    UniV3AnyForkAdapter adapter;

    function setUp() public {
        feeFactory = new MockFeeFactory();
        tsFactory = new MockTickSpacingFactory();

        address[] memory factories = new address[](2);
        factories[0] = address(feeFactory);
        factories[1] = address(tsFactory);
        bytes32[] memory hashes = new bytes32[](2); // both zero → registry lane, never CREATE2
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 100;
        tiers[1] = 500;
        tiers[2] = 3000;

        adapter = new UniV3AnyForkAdapter(ROUTER, factories, hashes, tiers);
    }

    /// Reaching the provenance check requires passing `onlyRouter` first, so every provenance
    /// assertion below is made as the router. A revert reason of PoolNotCanonical therefore proves
    /// the pool was rejected, and NOT that the caller was.
    function _swapAsRouter(address pool) internal {
        vm.prank(ROUTER);
        adapter.swap(T0, T1, 1e18, address(0xdead), abi.encode(pool));
    }

    // ── the lane this contract exists for ───────────────────────────────────────────────────────

    function test_tickSpacingKeyedPool_passesProvenance() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 0, 200); // no fee() — tickSpacing only
        tsFactory.set(T0, T1, 200, address(pool));
        // Reaching the pool's swap() proves the tickSpacing lane authenticated it. On
        // UniV3GenericAdapter this exact pool reverts PoolNotCanonical instead.
        vm.expectRevert(MockV3Pool.ReachedPoolSwap.selector);
        _swapAsRouter(address(pool));
    }

    function test_tickSpacingPool_unknownToFactory_isRejected() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 0, 200);
        // deliberately NOT registered — the factory returns address(0)
        vm.expectRevert(
            abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(pool))
        );
        _swapAsRouter(address(pool));
    }

    function test_tickSpacingPool_registeredUnderDifferentSpacing_isRejected() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 0, 200);
        tsFactory.set(T0, T1, 100, address(pool)); // registered at 100, pool reports 200
        vm.expectRevert(
            abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(pool))
        );
        _swapAsRouter(address(pool));
    }

    /// A hostile contract can claim any tickSpacing it likes; the factory is the authority.
    function test_poolLyingAboutSpacing_cannotForgeProvenance() public {
        MockV3Pool honest = new MockV3Pool(T0, T1, 0, 200);
        tsFactory.set(T0, T1, 200, address(honest));

        MockV3Pool impostor = new MockV3Pool(T0, T1, 0, 200); // same claims, never registered
        vm.expectRevert(
            abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(impostor))
        );
        _swapAsRouter(address(impostor));
    }

    // ── no regression on the lanes inherited from UniV3GenericAdapter ───────────────────────────

    function test_feeKeyedPool_stillPasses() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 500, 0); // fee only, no tickSpacing()
        feeFactory.set(T0, T1, 500, address(pool));
        vm.expectRevert(MockV3Pool.ReachedPoolSwap.selector);
        _swapAsRouter(address(pool));
    }

    /// The PangolinV3 lesson: a dynamic-fee fork's live `fee()` is not the fee it was registered
    /// under, so the pinned creation tiers must still be probed after the live value.
    function test_feeKeyedPool_liveFeeDiffersFromCreationTier_stillPasses() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 10, 0);   // reports 10
        feeFactory.set(T0, T1, 3000, address(pool));        // registered at a pinned tier
        vm.expectRevert(MockV3Pool.ReachedPoolSwap.selector);
        _swapAsRouter(address(pool));
    }

    function test_poolNoFactoryClaims_isRejected() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 500, 200); // both getters, neither registry has it
        vm.expectRevert(
            abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, address(pool))
        );
        _swapAsRouter(address(pool));
    }

    // ── H1 gate ────────────────────────────────────────────────────────────────────────────────

    function test_onlyRouter_rejectsStranger() public {
        MockV3Pool pool = new MockV3Pool(T0, T1, 0, 200);
        tsFactory.set(T0, T1, 200, address(pool));
        // No prank: msg.sender is the test contract, not the pinned router.
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(T0, T1, 1e18, address(0xdead), abi.encode(pool));
    }

    function test_nullRouterIsPinned() public view {
        assertEq(adapter.NULL_ROUTER(), ROUTER);
    }
}
