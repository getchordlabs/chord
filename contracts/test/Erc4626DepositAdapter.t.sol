// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Erc4626DepositAdapter} from "../src/adapters/Erc4626DepositAdapter.sol";
import {ChordErc4626DepositAdapter} from "../src/chord/ChordErc4626DepositAdapter.sol";
import {BaseAdapter} from "../src/adapters/BaseAdapter.sol";

contract D4MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "BAL");
        require(allowance[from][msg.sender] >= amt, "ALLOW");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// Wrapped native: `withdraw` burns the caller's balance and pays the coin, as WMON / WETH9 do.
contract D4MockWrapped is D4MockERC20 {
    function withdraw(uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "PAY");
    }

    receive() external payable {}
}

/// A vault whose shares are its own ERC-20 balance, minted at `rateBps` of the assets. `asset_` is an ERC-20 or the
/// native sentinel; a native vault wants msg.value == assets, as aprMON does (`InvalidAmount` otherwise).
contract D4MockVault is D4MockERC20 {
    address public immutable asset;
    uint256 public rateBps;
    uint256 public pullBps = 10_000; // share of `assets` an ERC-20 vault actually pulls

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error InvalidAmount();

    constructor(address asset_, uint256 rateBps_) {
        asset = asset_;
        rateBps = rateBps_;
    }

    function setPullBps(uint256 b) external {
        pullBps = b;
    }

    function setRateBps(uint256 b) external {
        rateBps = b;
    }

    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares) {
        if (asset == NATIVE) {
            if (msg.value != assets) revert InvalidAmount();
        } else {
            require(msg.value == 0, "VALUE");
            D4MockERC20(asset).transferFrom(msg.sender, address(this), assets * pullBps / 10_000);
        }
        shares = assets * rateBps / 10_000;
        balanceOf[receiver] += shares;
    }
}

contract Erc4626DepositAdapterTest is Test {
    address constant ROUTER = address(0xA11CE);
    address constant USER = address(0xB0B);
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    D4MockWrapped wmon;
    D4MockERC20 other;
    D4MockVault erc20Vault; // asset = WMON (the gMON shape)
    D4MockVault nativeVault; // asset = native sentinel (the aprMON / shMON shape)
    ChordErc4626DepositAdapter adapter;

    function setUp() public {
        wmon = new D4MockWrapped();
        other = new D4MockERC20();
        erc20Vault = new D4MockVault(address(wmon), 9_052);
        nativeVault = new D4MockVault(NATIVE, 9_120);
        adapter = new ChordErc4626DepositAdapter(ROUTER, address(wmon));
        vm.deal(address(wmon), 1_000 ether); // the coin behind the wrapped balances
    }

    function _fund(uint256 amt) internal {
        wmon.mint(address(adapter), amt);
    }

    function test_erc20AssetVault_depositsAndForwardsShares() public {
        _fund(10 ether);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(wmon), address(erc20Vault), 10 ether, USER, abi.encode(address(erc20Vault)));
        assertEq(out, 9.052 ether);
        assertEq(erc20Vault.balanceOf(USER), 9.052 ether, "shares to the recipient");
        assertEq(wmon.balanceOf(address(erc20Vault)), 10 ether, "the vault pulled the asset");
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(erc20Vault.balanceOf(address(adapter)), 0);
        assertEq(wmon.allowance(address(adapter), address(erc20Vault)), 0, "approval reset");
    }

    function test_nativeAssetVault_unwrapsAndSendsTheCoinAsValue() public {
        _fund(10 ether);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(wmon), address(nativeVault), 10 ether, USER, abi.encode(address(nativeVault)));
        assertEq(out, 9.12 ether);
        assertEq(nativeVault.balanceOf(USER), 9.12 ether);
        assertEq(address(nativeVault).balance, 10 ether, "the vault received the coin, not the wrapper");
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0, "no coin left in the adapter");
    }

    function test_onlyRouter() public {
        _fund(1 ether);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(wmon), address(erc20Vault), 1 ether, USER, abi.encode(address(erc20Vault)));
    }

    function test_vaultMustBeTheOutputToken() public {
        _fund(1 ether);
        vm.prank(ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(Erc4626DepositAdapter.VaultIsNotTokenOut.selector, address(nativeVault), address(erc20Vault))
        );
        adapter.swap(address(wmon), address(erc20Vault), 1 ether, USER, abi.encode(address(nativeVault)));
    }

    function test_assetMismatch_refusedBeforeAnyApprovalOrUnwrap() public {
        // tokenIn is not the vault's asset.
        other.mint(address(adapter), 1 ether);
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(Erc4626DepositAdapter.AssetMismatch.selector, address(wmon)));
        adapter.swap(address(other), address(erc20Vault), 1 ether, USER, abi.encode(address(erc20Vault)));
        assertEq(other.allowance(address(adapter), address(erc20Vault)), 0);

        // A native vault takes the coin only when the input is the WRAPPED coin.
        vm.prank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(Erc4626DepositAdapter.AssetMismatch.selector, NATIVE));
        adapter.swap(address(other), address(nativeVault), 1 ether, USER, abi.encode(address(nativeVault)));
    }

    function test_noShares_reverts() public {
        erc20Vault.setRateBps(0);
        _fund(1 ether);
        vm.prank(ROUTER);
        vm.expectRevert(Erc4626DepositAdapter.NoShares.selector);
        adapter.swap(address(wmon), address(erc20Vault), 1 ether, USER, abi.encode(address(erc20Vault)));
    }

    function test_vaultThatPullsLess_leftoverGoesToRecipient() public {
        erc20Vault.setPullBps(9_000);
        _fund(10 ether);
        vm.prank(ROUTER);
        adapter.swap(address(wmon), address(erc20Vault), 10 ether, USER, abi.encode(address(erc20Vault)));
        assertEq(wmon.balanceOf(USER), 1 ether, "the 10 % the vault did not pull");
        assertEq(wmon.balanceOf(address(adapter)), 0);
        assertEq(wmon.allowance(address(adapter), address(erc20Vault)), 0);
    }

    function test_sharesAlreadyInTheAdapter_areNotCounted() public {
        // Someone sent shares to the adapter: only this swap's mint is reported and forwarded.
        erc20Vault.mint(address(adapter), 5 ether);
        _fund(10 ether);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(wmon), address(erc20Vault), 10 ether, USER, abi.encode(address(erc20Vault)));
        assertEq(out, 9.052 ether);
        assertEq(erc20Vault.balanceOf(USER), 9.052 ether);
    }

    function test_nativeCoinFromAnyoneElse_isRefused() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory ret) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(ret), Erc4626DepositAdapter.UnexpectedNative.selector);
    }

    function test_constructorGuards() public {
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new ChordErc4626DepositAdapter(address(0), address(wmon));
        vm.expectRevert(Erc4626DepositAdapter.ZeroAddress.selector);
        new ChordErc4626DepositAdapter(ROUTER, address(0));
        assertEq(adapter.NULL_ROUTER(), ROUTER);
        assertEq(adapter.WRAPPED_NATIVE(), address(wmon));
    }

    function testFuzz_erc20Vault_sharesMatchTheRate(uint96 amt, uint16 rate) public {
        vm.assume(amt > 10_000 && rate > 0 && rate <= 20_000);
        erc20Vault.setRateBps(rate);
        _fund(amt);
        vm.prank(ROUTER);
        uint256 out = adapter.swap(address(wmon), address(erc20Vault), amt, USER, abi.encode(address(erc20Vault)));
        assertEq(out, uint256(amt) * rate / 10_000);
        assertEq(erc20Vault.balanceOf(USER), out);
    }
}
