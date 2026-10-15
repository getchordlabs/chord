// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {ChordAdapterRegistry} from "../src/chord/ChordAdapterRegistry.sol";
import {ChordFeeCollector} from "../src/chord/ChordFeeCollector.sol";
import {ChordRouter} from "../src/chord/ChordRouter.sol";

/// @notice The Chord-named implementations (src/chord) are the same contracts under a new name: a live
///         NullRouter / AdapterRegistry / FeeCollector proxy must upgrade to them with every piece of state intact
///         (script/UpgradeChordNames.s.sol on Avalanche), and only the owner may do it.
contract ChordNamesTest is Test {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal wnative = makeAddr("wnative");
    address internal adapterA = makeAddr("adapterA");

    AdapterRegistry internal registry;
    FeeCollector internal collector;
    NullRouter internal router;

    function setUp() public {
        registry = AdapterRegistry(address(new ERC1967Proxy(address(new AdapterRegistry()), abi.encodeCall(AdapterRegistry.initialize, (owner)))));
        router = NullRouter(payable(address(new ERC1967Proxy(
            address(new NullRouter()),
            abi.encodeCall(NullRouter.initialize, (owner, wnative, address(0), address(1), address(registry)))
        ))));
        collector = FeeCollector(address(new ERC1967Proxy(
            address(new FeeCollector()),
            abi.encodeCall(FeeCollector.initialize, (owner, treasury, address(router), 25, 5000))
        )));
        vm.startPrank(owner);
        router.setFeeCollector(address(collector));
        registry.addAdapter(adapterA);
        vm.stopPrank();
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function test_upgradeToChordImplsKeepsEveryPieceOfState() public {
        address ri = address(new ChordAdapterRegistry());
        address ci = address(new ChordFeeCollector());
        address xi = address(new ChordRouter());
        vm.startPrank(owner);
        UUPSUpgradeable(address(registry)).upgradeToAndCall(ri, "");
        UUPSUpgradeable(address(collector)).upgradeToAndCall(ci, "");
        UUPSUpgradeable(address(router)).upgradeToAndCall(xi, "");
        vm.stopPrank();

        assertEq(_impl(address(registry)), ri);
        assertEq(_impl(address(collector)), ci);
        assertEq(_impl(address(router)), xi);
        assertEq(router.owner(), owner);
        assertEq(router.wmon(), wnative);
        assertEq(address(router.registry()), address(registry));
        assertEq(address(router.feeCollector()), address(collector));
        assertTrue(registry.isApproved(adapterA));
        assertEq(registry.getApprovedAdapters().length, 1);
        assertEq(collector.treasury(), treasury);
        assertEq(collector.feeBps(), 25);
        assertEq(collector.referralShareBps(), 5000);

        // owner powers survive the upgrade
        vm.startPrank(owner);
        registry.addAdapter(makeAddr("adapterB"));
        collector.setFeeBps(30);
        vm.stopPrank();
        assertEq(registry.getApprovedAdapters().length, 2);
        assertEq(collector.feeBps(), 30);
    }

    function test_onlyTheOwnerUpgrades() public {
        address xi = address(new ChordRouter());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        UUPSUpgradeable(address(router)).upgradeToAndCall(xi, "");
    }

    function test_chordImplsCannotBeInitialisedDirectly() public {
        ChordRouter impl = new ChordRouter();
        vm.expectRevert();
        impl.initialize(owner, wnative, address(0), address(1), address(registry));
    }
}
