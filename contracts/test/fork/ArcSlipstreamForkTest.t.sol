// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordV3Adapter} from "../../src/chord/ChordAdapters.sol";
import {UniV3AnyForkAdapter} from "../../src/adapters/UniV3AnyForkAdapter.sol";

interface IERC20Arc {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IClPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
}

/// @dev Opens the adapter's provenance check: on a fork that is the part of a swap this suite can run (see below).
contract ProvenanceProbe is ChordV3Adapter {
    constructor(address r, address[] memory f, bytes32[] memory h, uint24[] memory t) ChordV3Adapter(r, f, h, t) {}

    function check(address pool) external view {
        _requireCanonicalPool(pool, IClPool(pool).token0(), IClPool(pool).token1());
    }
}

/// @notice Arc fork: the any-fork V3 adapter with Arc's four concentrated-liquidity factories pinned — Uniswap V3 and Synthra
///         (fee-keyed registries, the two the live r2 adapter serves) plus the two tick-spacing-keyed ones KyberSwap routes
///         USDC / EURC through and Chord did not: `aero-cl` 0xb89df768… and `archery-v3` 0xc481038c… (2026-10-13: the
///         aero-cl pool holds ~30x the liquidity of Uniswap V3's USDC / EURC pool; `getPool(address,address,uint24)` answers
///         zero on the first and reverts on the second, `getPool(address,address,int24)` names the pool on both).
///         What a fork can prove here is PROVENANCE: each real pool authenticates against its real factory, and a pool of
///         no pinned factory is refused. It cannot run the swap itself: Arc's USDC is the gas coin seen through a predeploy
///         whose transfer is the node's own, and in a local fork that transfer fails (`TransferFailed`, also on the Uniswap
///         V3 pool that swaps on mainnet every day). The swap is proven both ways on mainnet
///         (docs/contracts-verification.md, Arc). Run: forge test --match-contract ArcSlipstreamForkTest (kept out of CI
///         with the other *ForkTest suites; ARC_FORK_RPC overrides the public endpoint).
contract ArcSlipstreamForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address constant SYNTHRA_V3_FACTORY = 0x6307fc239C7964942c1BfFE51930E55606619c74;
    address constant AERO_CL_FACTORY = 0xb89Df768aF2CFE637ceB352c587Fe8edAf491d03;
    address constant ARCHERY_FACTORY = 0xC481038C013FE96F38CE7A2dC417b2B1B78b16A4;
    address constant AERO_USDC_EURC = 0xbe080aC37ad1305DFCc9521F5e6F68CFDc41B7fa;
    address constant ARCHERY_USDC_EURC = 0xb88C08E31C1bC7d41f2cFc4FbAfAD5B3B0a5eAe9;
    address constant UNI_USDC_EURC = 0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1;


    ProvenanceProbe adapter;

    function _pinned(uint256 n) internal pure returns (address[] memory f) {
        address[4] memory all = [UNISWAP_V3_FACTORY, SYNTHRA_V3_FACTORY, AERO_CL_FACTORY, ARCHERY_FACTORY];
        f = new address[](n);
        for (uint256 i = 0; i < n; i++) f[i] = all[i];
    }

    function _tiers() internal pure returns (uint24[] memory t) {
        t = new uint24[](4);
        t[0] = 100;
        t[1] = 500;
        t[2] = 3000;
        t[3] = 10000;
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_FORK_RPC", string("https://rpc.mainnet.arc.io")));
        require(block.chainid == 5042, "not Arc");
        adapter = new ProvenanceProbe(ROUTER, _pinned(4), new bytes32[](4), _tiers()); // zero hash = the factory's own registry is asked
    }

    function test_the_two_tickSpacing_keyed_pools_authenticate() public view {
        assertEq(IClPool(AERO_USDC_EURC).tickSpacing(), 1);
        adapter.check(AERO_USDC_EURC);
        adapter.check(ARCHERY_USDC_EURC);
    }

    function test_the_uniswapV3_pool_still_authenticates() public view {
        adapter.check(UNI_USDC_EURC);
    }

    function test_a_pool_of_no_pinned_factory_is_refused() public {
        // what the live r2 adapter is: only the two fee-keyed factories
        ProvenanceProbe r2Like = new ProvenanceProbe(ROUTER, _pinned(2), new bytes32[](2), _tiers());
        r2Like.check(UNI_USDC_EURC);
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, AERO_USDC_EURC));
        r2Like.check(AERO_USDC_EURC);
        vm.expectRevert(abi.encodeWithSelector(UniV3AnyForkAdapter.PoolNotCanonical.selector, ARCHERY_USDC_EURC));
        r2Like.check(ARCHERY_USDC_EURC);
    }

    function test_the_swap_reaches_the_pool_and_only_the_router_may_start_it() public {
        // not the router: refused before anything else
        vm.expectRevert();
        adapter.swap(USDC, EURC, 1e6, address(0xB0B), abi.encode(AERO_USDC_EURC));
        // the router: provenance passes, the pool calls back, and the fork stops at the predeploy's transfer
        vm.deal(address(adapter), 1e6 * 1e12);
        assertEq(IERC20Arc(USDC).balanceOf(address(adapter)), 1e6, "the predeploy does not show the coin");
        vm.prank(ROUTER);
        vm.expectRevert(bytes4(keccak256("TransferFailed()")));
        adapter.swap(USDC, EURC, 1e6, address(0xB0B), abi.encode(AERO_USDC_EURC));
    }
}
