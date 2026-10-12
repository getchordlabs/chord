// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordErc4626DepositAdapter} from "../../src/chord/ChordErc4626DepositAdapter.sol";

interface IVaultView {
    function asset() external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Monad mainnet fork: the Chord ERC-4626 deposit adapter against the three liquid-staking vaults read
///         on-chain 2026-10-12 — aprMON and shMON (asset = the native-coin sentinel, the coin goes in as msg.value)
///         and gMON (asset = WMON). Each mint is compared with the vault's own `previewDeposit` at the same block.
///         Run:  forge test --match-contract Erc4626DepositForkTest --fork-url https://rpc.monad.xyz -vv
///         (Monad needs --fork-url; a fork created inside the test fails with "cannot create a monad fork with an
///         EVM instantiated for ethereum".) Every test skips itself on any other chain. Excluded from CI with the
///         other *ForkTest suites.
contract Erc4626DepositForkTest is Test {
    address constant ROUTER = 0x1B1Fee89A381E595Fe6536b99Ba91F3E16e9601a; // Chord router proxy
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant APRMON = 0x0c65A0BC65a5D819235B71F554D210D3F80E0852;
    address constant SHMON = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address constant GMON = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;
    address constant USER = address(0xB0B);

    ChordErc4626DepositAdapter adapter;

    function setUp() public {
        if (block.chainid != 143) return;
        adapter = new ChordErc4626DepositAdapter(ROUTER, WMON);
    }

    function _mint(address vault, address expectedAsset, uint256 amt) internal {
        if (block.chainid != 143) return;
        assertEq(IVaultView(vault).asset(), expectedAsset, "asset() changed");
        uint256 preview = IVaultView(vault).previewDeposit(amt);
        deal(WMON, address(adapter), amt);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(WMON, vault, amt, USER, abi.encode(vault));
        console2.log("shares", out, "previewDeposit", preview);
        assertEq(IVaultView(vault).balanceOf(USER), out, "delivered != returned");
        // ERC-4626: deposit mints no fewer shares than previewDeposit in the same transaction.
        assertGe(out, preview, "minted fewer shares than previewDeposit");
        assertLe(out - preview, preview / 1_000_000, "minted more than 1 ppm above previewDeposit");
        assertEq(IERC20D(WMON).balanceOf(address(adapter)), 0, "WMON left in the adapter");
        assertEq(address(adapter).balance, 0, "coin left in the adapter");
        assertEq(IVaultView(vault).balanceOf(address(adapter)), 0, "shares left in the adapter");
    }

    function test_monad_aprMON_nativeAsset_mintsAtPreview() public {
        _mint(APRMON, NATIVE, 1_000 ether);
    }

    function test_monad_shMON_nativeAsset_mintsAtPreview() public {
        _mint(SHMON, NATIVE, 1_000 ether);
    }

    function test_monad_gMON_wmonAsset_mintsAtPreview() public {
        _mint(GMON, WMON, 1_000 ether);
    }

    /// 400,000 MON (about 10,000 USD on 2026-10-12): the rate does not move with size.
    function test_monad_aprMON_largeMint_sameRate() public {
        if (block.chainid != 143) return;
        uint256 small = IVaultView(APRMON).previewDeposit(1 ether);
        _mint(APRMON, NATIVE, 400_000 ether);
        uint256 got = IVaultView(APRMON).balanceOf(USER);
        assertApproxEqRel(got, small * 400_000, 1e12, "rate moved with size"); // within 1e-6
    }
}
