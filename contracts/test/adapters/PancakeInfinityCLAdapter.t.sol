// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {
    PancakeInfinityCLAdapter,
    InfinityPoolKey,
    IInfinityCLPoolManager
} from "../../src/adapters/PancakeInfinityCLAdapter.sol";
import {ChordInfinityCLAdapter} from "../../src/chord/ChordInfinityCLAdapter.sol";

contract TokenInf {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

contract WrappedNativeInf {
    mapping(address => uint256) public balanceOf;
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v;
        (bool ok,) = msg.sender.call{value: v}("");
        require(ok, "ETH");
    }
    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "BAL");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

interface ILockerInf {
    function lockAcquired(bytes calldata data) external returns (bytes memory);
}

/// @dev Infinity Vault accounting in miniature: per-currency deltas for the locker (positive = owed TO the locker),
///      sync + settle measures what arrived, take pays out, and `lock` fails unless every delta is back to zero.
contract VaultInf {
    mapping(address => int256) public delta;
    uint256 internal nonzero;
    address internal synced;
    bool internal hasSynced;
    uint256 internal syncedReserve;

    function lock(bytes calldata data) external returns (bytes memory r) {
        r = ILockerInf(msg.sender).lockAcquired(data);
        require(nonzero == 0, "CurrencyNotSettled");
    }

    function accountDelta(address currency, int256 d) external { _add(currency, d); }

    function _add(address c, int256 d) internal {
        int256 prev = delta[c];
        int256 next = prev + d;
        if (prev == 0 && next != 0) nonzero++;
        else if (prev != 0 && next == 0) nonzero--;
        delta[c] = next;
    }

    function sync(address c) external {
        synced = c;
        hasSynced = true;
        syncedReserve = TokenInf(c).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (hasSynced) {
            require(msg.value == 0, "NATIVE_ON_ERC20");
            paid = TokenInf(synced).balanceOf(address(this)) - syncedReserve;
            _add(synced, int256(paid));
            hasSynced = false;
        } else {
            paid = msg.value;
            _add(address(0), int256(paid));
        }
    }

    function take(address c, address to, uint256 amount) external {
        _add(c, -int256(amount));
        if (c == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETH");
        } else {
            TokenInf(c).transfer(to, amount);
        }
    }

    receive() external payable {}
}

/// @dev Fixed-price CL pool manager: out = in × 2 (or in / 2 the other way); `partialFill` charges half the input.
contract CLPoolManagerInf {
    VaultInf public immutable vault;
    bool public partialFill;
    InfinityPoolKey public lastKey;

    constructor(VaultInf v) { vault = v; }

    function setPartial(bool p) external { partialFill = p; }

    function swap(InfinityPoolKey memory key, IInfinityCLPoolManager.SwapParams memory p, bytes calldata)
        external
        returns (int256)
    {
        require(p.amountSpecified < 0, "exact input only");
        lastKey = key;
        uint256 amtIn = uint256(-p.amountSpecified);
        if (partialFill) amtIn /= 2;
        uint256 out = p.zeroForOne ? amtIn * 2 : amtIn / 2;
        int128 d0;
        int128 d1;
        if (p.zeroForOne) {
            d0 = -int128(int256(amtIn));
            d1 = int128(int256(out));
        } else {
            d1 = -int128(int256(amtIn));
            d0 = int128(int256(out));
        }
        vault.accountDelta(key.currency0, d0);
        vault.accountDelta(key.currency1, d1);
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }
}

contract PancakeInfinityCLAdapterTest is Test {
    address constant ROUTER = address(0xA11CE);
    address constant USER = address(0xB0B);
    TokenInf a;
    TokenInf b;
    WrappedNativeInf wnative;
    VaultInf vault;
    CLPoolManagerInf pm;
    PancakeInfinityCLAdapter adapter;

    function setUp() public {
        TokenInf x = new TokenInf();
        TokenInf y = new TokenInf();
        (a, b) = address(x) < address(y) ? (x, y) : (y, x);
        wnative = new WrappedNativeInf();
        vault = new VaultInf();
        pm = new CLPoolManagerInf(vault);
        adapter = new ChordInfinityCLAdapter(ROUTER, address(vault), address(pm), address(wnative));
        a.mint(address(vault), 1_000_000e18);
        b.mint(address(vault), 1_000_000e18);
        vm.deal(address(vault), 1_000e18);
    }

    function _key(address c0, address c1) internal view returns (InfinityPoolKey memory) {
        return InfinityPoolKey(c0, c1, address(0), address(pm), 67, bytes32(uint256(1) << 16));
    }

    function _swap(address tin, address tout, uint256 amt, InfinityPoolKey memory k) internal returns (uint256) {
        vm.prank(ROUTER);
        return adapter.swap(tin, tout, amt, USER, abi.encode(k));
    }

    function test_zeroForOne_paysTheVaultAndDeliversTheOutput() public {
        a.mint(address(adapter), 100e18);
        uint256 out = _swap(address(a), address(b), 100e18, _key(address(a), address(b)));
        assertEq(out, 200e18);
        assertEq(b.balanceOf(USER), 200e18);
        assertEq(a.balanceOf(address(adapter)), 0, "input left behind");
        assertEq(vault.delta(address(a)), 0);
        assertEq(vault.delta(address(b)), 0);
    }

    function test_oneForZero() public {
        b.mint(address(adapter), 100e18);
        uint256 out = _swap(address(b), address(a), 100e18, _key(address(a), address(b)));
        assertEq(out, 50e18);
        assertEq(a.balanceOf(USER), 50e18);
        assertEq(b.balanceOf(address(adapter)), 0);
    }

    function test_nativeIn_unwrapsAndSettlesNative() public {
        vm.deal(ROUTER, 1e18);
        vm.prank(ROUTER);
        wnative.deposit{value: 1e18}();
        vm.prank(ROUTER);
        wnative.transfer(address(adapter), 1e18);
        uint256 out = _swap(address(wnative), address(b), 1e18, _key(address(0), address(b)));
        assertEq(out, 2e18);
        assertEq(b.balanceOf(USER), 2e18);
        assertEq(wnative.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(pm.partialFill(), false);
        (address c0,,,,,) = pm.lastKey();
        assertEq(c0, address(0), "the pool is keyed on native, not the wrapper");
    }

    function test_nativeOut_deliversTheWrapper() public {
        b.mint(address(adapter), 4e18);
        uint256 out = _swap(address(b), address(wnative), 4e18, _key(address(0), address(b)));
        assertEq(out, 2e18); // oneForZero: the mock pool halves
        assertEq(wnative.balanceOf(USER), 2e18);
        assertEq(address(adapter).balance, 0);
    }

    function test_onlyRouter() public {
        a.mint(address(adapter), 1e18);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(a), address(b), 1e18, USER, abi.encode(_key(address(a), address(b))));
    }

    function test_rejectsAKeyNamingAnotherPoolManager() public {
        a.mint(address(adapter), 1e18);
        InfinityPoolKey memory k = _key(address(a), address(b));
        k.poolManager = address(0xBAD);
        vm.prank(ROUTER);
        vm.expectRevert(PancakeInfinityCLAdapter.WrongPoolManager.selector);
        adapter.swap(address(a), address(b), 1e18, USER, abi.encode(k));
    }

    function test_rejectsAKeyThatDoesNotNameTheRouteTokens() public {
        TokenInf c = new TokenInf();
        a.mint(address(adapter), 1e18);
        vm.prank(ROUTER);
        vm.expectRevert(PancakeInfinityCLAdapter.KeyNotBoundToRoute.selector);
        adapter.swap(address(a), address(c), 1e18, USER, abi.encode(_key(address(a), address(b))));
        // Native key, but the route says the input is some token other than the wrapper.
        vm.prank(ROUTER);
        vm.expectRevert(PancakeInfinityCLAdapter.KeyNotBoundToRoute.selector);
        adapter.swap(address(a), address(b), 1e18, USER, abi.encode(_key(address(0), address(b))));
    }

    function test_lockAcquiredOnlyFromTheVault() public {
        vm.expectRevert(PancakeInfinityCLAdapter.NotVault.selector);
        adapter.lockAcquired("");
    }

    function test_partialFillReverts() public {
        pm.setPartial(true);
        a.mint(address(adapter), 100e18);
        vm.prank(ROUTER);
        vm.expectRevert(PancakeInfinityCLAdapter.PartialFill.selector);
        adapter.swap(address(a), address(b), 100e18, USER, abi.encode(_key(address(a), address(b))));
    }

    function test_pinsRouterAndInfinityContracts() public view {
        assertEq(adapter.NULL_ROUTER(), ROUTER);
        assertEq(address(adapter.VAULT()), address(vault));
        assertEq(address(adapter.CL_POOL_MANAGER()), address(pm));
        assertEq(adapter.WRAPPED_NATIVE(), address(wnative));
    }
}
