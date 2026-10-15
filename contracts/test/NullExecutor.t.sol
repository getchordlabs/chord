// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullExecutor} from "../src/NullExecutor.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";

/// Minimal ERC20 (TransferLib only needs transfer/transferFrom to exist and return true).
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// The L9 primitive: an attacker-deployed "registry" that approves the attacker. Pre-fix the
/// executor called THIS, believed it, and TransferLib moved its own balance to the "adapter".
contract EvilRegistry is IAdapterRegistry {
    function isApproved(address) external pure returns (bool) { return true; }
    function addAdapter(address) external {}
    function removeAdapter(address) external {}
    function getApprovedAdapters() external pure returns (address[] memory a) { a = new address[](0); }
}

/// The "adapter" the evil registry rubber-stamps: it keeps whatever it is sent and reports a swap.
/// It must be a CONTRACT returning a well-formed uint256, otherwise the drain reverts on decode and
/// masks the finding.
contract EvilAdapter {
    function swap(address, address, uint256 amountIn, address, bytes calldata) external pure returns (uint256) {
        return amountIn;
    }
}

/// L9 (audit 2026-08-05): `NullExecutor` is out of the swap path since the 2026-03-20 delegatecall
/// removal, but the deployed instance is still callable by anyone, and its whitelist used to be a
/// CALLER-SUPPLIED argument. These tests pin the registry to the one fixed at construction.
contract NullExecutorRegistryTest is Test {
    NullExecutor executor;
    AdapterRegistry registry;
    EvilRegistry evil;
    EvilAdapter evilAdapter;
    MockERC20 tA;
    MockERC20 tB;

    address attacker = address(0xBAD);

    function setUp() public {
        AdapterRegistry impl = new AdapterRegistry();
        registry = AdapterRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(AdapterRegistry.initialize, (address(this)))))
        );
        executor = new NullExecutor(address(registry));
        evil = new EvilRegistry();
        evilAdapter = new EvilAdapter();
        tA = new MockERC20();
        tB = new MockERC20();
    }

    function _step(address adapter) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({
            adapter: adapter,
            tokenIn: address(tA),
            tokenOut: address(tB),
            amountIn: 1 ether,
            extraData: ""
        });
    }

    /// The whole finding in one call: the attacker names their own contract as the adapter and
    /// supplies a registry that rubber-stamps it. Pre-fix this call SUCCEEDS and the executor's
    /// entire tA balance ends up in the attacker's adapter; now it reverts before any transfer.
    function test_callerSuppliedRegistryIsRejected() public {
        tA.mint(address(executor), 1 ether); // whatever the executor happens to hold

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(NullExecutor.RegistryMismatch.selector, address(evil), address(registry))
        );
        executor.executeSingle(_step(address(evilAdapter)), IAdapterRegistry(address(evil)));

        assertEq(tA.balanceOf(address(evilAdapter)), 0, "no sweep");
        assertEq(tA.balanceOf(address(executor)), 1 ether, "balance untouched");
    }

    function test_callerSuppliedRegistryIsRejected_split() public {
        tA.mint(address(executor), 2 ether);
        INullRouter.RouteStep[] memory steps = new INullRouter.RouteStep[](1);
        steps[0] = _step(address(evilAdapter));
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(NullExecutor.RegistryMismatch.selector, address(evil), address(registry))
        );
        executor.executeSplit(address(tA), address(tB), steps, IAdapterRegistry(address(evil)));
    }

    function test_callerSuppliedRegistryIsRejected_multiHop() public {
        tA.mint(address(executor), 2 ether);
        INullRouter.RouteStep[] memory steps = new INullRouter.RouteStep[](2);
        steps[0] = _step(address(evilAdapter));
        steps[1] = _step(address(evilAdapter));
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(NullExecutor.RegistryMismatch.selector, address(evil), address(registry))
        );
        executor.executeMultiHop(steps, IAdapterRegistry(address(evil)));
    }

    /// Supplying the RIGHT registry still enforces the real whitelist — the pinned registry is a
    /// gate, not a bypass.
    function test_pinnedRegistryStillEnforcesWhitelist() public {
        vm.expectRevert(abi.encodeWithSelector(NullExecutor.UnapprovedAdapter.selector, attacker));
        executor.executeSingle(_step(attacker), IAdapterRegistry(address(registry)));
    }

    function test_registryIsImmutableAndNonZero() public {
        assertEq(address(executor.REGISTRY()), address(registry));
        vm.expectRevert(NullExecutor.ZeroRegistry.selector);
        new NullExecutor(address(0));
    }
}
