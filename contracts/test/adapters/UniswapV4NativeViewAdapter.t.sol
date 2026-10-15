// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {UniswapV4NativeViewAdapter, PoolKey, IPoolManager} from "../../src/adapters/UniswapV4NativeViewAdapter.sol";

/// @title UniswapV4NativeViewAdapter — Arc (5042) V4 adapter over the USDC predeploy
/// @notice The chain fact under test (measured on Arc 2026-09-16): the gas token is USDC with an
///         18-dec native unit, and the ERC-20 predeploy 0x3600…0000 is a 6-dec VIEW of the same
///         balance (`balanceOf(a) == a.balance / 1e12`, `transfer` moves native). So "wrap" is a
///         decimal scale, not a contract call. The adapter must:
///           · pay a native-in leg by value = amountIn * 1e12 (the router's 6-dec push IS that wei);
///           · deliver a native-out leg as raw / 1e12 predeploy units, dust staying behind;
///           · keep the pool's real `hooks` in the key (launchpad pools are hooked, fee = 0);
///           · settle what the delta says (a hook can charge less than amountSpecified), never more.
///
///         The test contract stands in for NullRouter (pinned `NULL_ROUTER`), mirroring production:
///         the router PUSHes tokenIn to the adapter, then calls swap(). The predeploy's view
///         semantics are emulated by `vm.deal`-ing the adapter the native wei the push would carry.

// ---------------------------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------------------------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "BAL");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Stands in for the 0x3600 predeploy: `balanceOf` is the holder's NATIVE balance / 1e12 plus
///      a ledger of view-unit transfers (a mock cannot move another account's native, so a transfer
///      debits/credits the ledger instead — the arithmetic the adapter sees is the same).
contract MockNativeView {
    uint256 constant SCALE = 1e12;
    mapping(address => int256) public ledger;

    function balanceOf(address a) public view returns (uint256) {
        return uint256(int256(a.balance / SCALE) + ledger[a]);
    }

    function mint(address to, uint256 amt) external { ledger[to] += int256(amt); }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf(msg.sender) >= amt, "ERC20: transfer amount exceeds balance");
        ledger[msg.sender] -= int256(amt);
        ledger[to] += int256(amt);
        return true;
    }
}

/// @dev Records the swap it was asked for, pays out at a fixed rate, and enforces the settle/take
///      accounting the real PoolManager does (value received on settle for native, ERC-20 balance
///      for tokens; take pays out from its own holdings).
contract MockPoolManager {
    PoolKey public lastKey;
    IPoolManager.SwapParams public lastParams;
    /// @dev output per 1e18 of input, in raw pool units (both currencies) — set per test.
    uint256 public rateE18;
    /// @dev raw input the pool actually charges (a hook may charge less than amountSpecified).
    uint256 public chargeOverride;
    uint256 public settledValue;
    address public syncedCurrency;
    bool public unlocked;

    function setRate(uint256 r) external { rateE18 = r; }
    function setCharge(uint256 c) external { chargeOverride = c; }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlocked = true;
        bytes memory r = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        return r;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external returns (int256 balanceDelta)
    {
        require(unlocked, "LOCKED");
        lastKey = key;
        lastParams = params;
        uint256 amtIn = uint256(-params.amountSpecified);
        uint256 charged = chargeOverride == 0 ? amtIn : chargeOverride;
        uint256 out = (charged * rateE18) / 1e18;
        int128 d0;
        int128 d1;
        if (params.zeroForOne) {
            d0 = -int128(uint128(charged));
            d1 = int128(uint128(out));
        } else {
            d1 = -int128(uint128(charged));
            d0 = int128(uint128(out));
        }
        balanceDelta = (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function sync(address currency) external { syncedCurrency = currency; }

    function settle() external payable returns (uint256) {
        settledValue = msg.value;
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "NATIVE_TAKE");
        } else {
            MockERC20(currency).transfer(to, amount);
        }
    }

    receive() external payable {}
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

contract UniswapV4NativeViewAdapterTest is Test {
    uint256 constant SCALE = 1e12;
    address constant STRANGER = address(0xBEEF);
    address constant HOOK = address(0xb6A65950534F061618B4AE102FBcbb8541a8e0cC); // minara.ai hook, Arc

    MockPoolManager pm;
    MockNativeView usdc; // the 0x3600 predeploy stand-in
    MockERC20 meme;
    UniswapV4NativeViewAdapter adapter;

    function setUp() public {
        pm = new MockPoolManager();
        usdc = new MockNativeView();
        meme = new MockERC20();
        adapter = new UniswapV4NativeViewAdapter(address(this), address(pm), address(usdc), 12);
        // The pool holds both sides.
        vm.deal(address(pm), 1_000_000e18);
        meme.mint(address(pm), 1_000_000_000e18);
    }

    function _key() internal pure returns (PoolKey memory) {
        // currency0 = native (address(0)) sorts first; fee 0 / ts 25 / hooked — the Minara pool shape.
        return PoolKey({currency0: address(0), currency1: address(0), fee: 0, tickSpacing: 25, hooks: HOOK});
    }

    function _keyWithMeme() internal view returns (PoolKey memory k) {
        k = _key();
        k.currency1 = address(meme);
    }

    // ── construction ────────────────────────────────────────────────────────────────────────────

    function test_pinsRouterAndScale() public view {
        assertEq(adapter.NULL_ROUTER(), address(this));
        assertEq(adapter.NATIVE_VIEW(), address(usdc));
        assertEq(adapter.SCALE(), SCALE);
        assertEq(address(adapter.POOL_MANAGER()), address(pm));
    }

    function test_rejectsACallerThatIsNotTheRouter() public {
        vm.prank(STRANGER);
        vm.expectRevert(BaseAdapter.NotRouter.selector);
        adapter.swap(address(usdc), address(meme), 1e6, address(this), abi.encode(_keyWithMeme()));
    }

    // ── native-in (USDC -> meme): value = amountIn * 1e12 ─────────────────────────────────────────

    function test_nativeIn_settlesScaledValueAndKeepsTheHook() public {
        pm.setRate(200e18); // 200 meme per 1 raw unit -> 100 USDC = 1e20 wei -> 2e22 meme
        uint256 amountIn = 100e6; // 100 USDC in predeploy units
        // Router push: the predeploy transfer credits native wei to the adapter (view semantics).
        vm.deal(address(adapter), amountIn * SCALE);

        uint256 out = adapter.swap(address(usdc), address(meme), amountIn, address(this), abi.encode(_keyWithMeme()));

        assertEq(pm.settledValue(), amountIn * SCALE, "native-in must settle amountIn * 1e12 by value");
        assertEq(address(adapter).balance, 0, "the whole scaled input left the adapter");
        (,, uint24 fee, int24 ts, address hooks) = pm.lastKey();
        assertEq(hooks, HOOK, "the real hook must reach the PoolManager (poolId = hash of the full key)");
        assertEq(fee, 0);
        assertEq(ts, 25);
        (bool zfo, int256 spec,) = pm.lastParams();
        assertTrue(zfo, "native is currency0 -> zeroForOne");
        assertEq(spec, -int256(amountIn * SCALE), "exact input in RAW pool units");
        assertEq(out, 2e22, "meme out is raw (18-dec), unscaled");
        assertEq(meme.balanceOf(address(this)), 2e22, "delivered to the recipient");
    }

    function test_nativeIn_settlesOnlyWhatTheDeltaCharges() public {
        // A hook with beforeSwapReturnsDelta may charge less than amountSpecified; the adapter must
        // settle the delta, not its own number — over-paying is a silent loss.
        pm.setRate(1e18);
        pm.setCharge(90e18);
        vm.deal(address(adapter), 100e18);
        adapter.swap(address(usdc), address(meme), 100e6, address(this), abi.encode(_keyWithMeme()));
        assertEq(pm.settledValue(), 90e18);
        assertEq(address(adapter).balance, 10e18, "the uncharged remainder stays with the adapter");
    }

    // ── native-out (meme -> USDC): raw / 1e12 forwarded through the predeploy ─────────────────────

    function test_nativeOut_forwardsScaledUnitsAndLeavesDust() public {
        // 1 raw meme -> 0.5 wei? no: rate is per 1e18 input. 10,000 meme (1e22) at 4.424e-3 -> 44.24 USDC.
        pm.setRate(4_424_156_036_115_885); // 0.004424156036115885 USDC(18-dec wei) per meme wei
        uint256 amountIn = 10_000e18;
        meme.mint(address(adapter), amountIn); // router push

        address to = address(0x7070); // zero native balance, so the view reads the ledger alone
        uint256 out = adapter.swap(address(meme), address(usdc), amountIn, to, abi.encode(_keyWithMeme()));

        uint256 rawOut = (amountIn * 4_424_156_036_115_885) / 1e18; // 44_241_560_361_158_850_000 wei
        assertEq(out, rawOut / SCALE, "amountOut is in predeploy units");
        assertEq(out, 44_241_560, "44.241560 USDC");
        assertEq(usdc.balanceOf(to), out, "forwarded through the predeploy's transfer");
        // The view hides the sub-unit remainder: rawOut % 1e12 wei stays with the adapter but reads
        // as 0 predeploy units — dust by construction.
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing visible is left behind");
        assertLt(rawOut % SCALE, SCALE);
        (bool zfo,,) = pm.lastParams();
        assertFalse(zfo, "meme is currency1 -> oneForZero");
        assertEq(pm.syncedCurrency(), address(meme), "ERC-20 input goes sync -> transfer -> settle");
        assertEq(meme.balanceOf(address(pm)), 1_000_000_000e18 + amountIn);
    }

    // ── ERC-20 ↔ ERC-20 pools (predeploy as an ERC-20 currency, PCH/LIFT shape) are unscaled ────

    function test_erc20Pool_isUnscaled() public {
        MockERC20 other = new MockERC20();
        other.mint(address(pm), 1e30);
        pm.setRate(3e18);
        PoolKey memory k = PoolKey({currency0: address(usdc), currency1: address(other), fee: 0, tickSpacing: 25, hooks: HOOK});
        if (address(usdc) > address(other)) (k.currency0, k.currency1) = (k.currency1, k.currency0);
        usdc.mint(address(adapter), 5e6);
        uint256 out = adapter.swap(address(usdc), address(other), 5e6, address(this), abi.encode(k));
        assertEq(pm.settledValue(), 0, "no value for an ERC-20 leg");
        assertEq(out, 15e6, "raw in, raw out");
        assertEq(other.balanceOf(address(this)), 15e6);
    }

    // ── H1: the key is bound to the route ────────────────────────────────────────────────────────

    function test_refusesAKeyWhoseCurrenciesAreNotTheRoute() public {
        MockERC20 other = new MockERC20();
        vm.deal(address(adapter), 1e18);
        PoolKey memory k = _keyWithMeme();
        vm.expectRevert(UniswapV4NativeViewAdapter.KeyNotBoundToRoute.selector);
        adapter.swap(address(usdc), address(other), 1e6, address(this), abi.encode(k));
    }

    function test_refusesANativeKeyWhenTheRouteSaysAnotherToken() public {
        // currency0 = native maps to NATIVE_VIEW only; a route claiming meme->meme must not pass.
        PoolKey memory k = _keyWithMeme();
        vm.expectRevert(UniswapV4NativeViewAdapter.KeyNotBoundToRoute.selector);
        adapter.swap(address(meme), address(meme), 1e18, address(this), abi.encode(k));
    }

    function test_onlyThePoolManagerMayCallBack() public {
        vm.prank(STRANGER);
        vm.expectRevert(UniswapV4NativeViewAdapter.NotPoolManager.selector);
        adapter.unlockCallback("");
    }

    function test_scaledInputMustFitInt128() public {
        vm.expectRevert(UniswapV4NativeViewAdapter.AmountOverflow.selector);
        adapter.swap(address(usdc), address(meme), uint256(type(uint128).max), address(this), abi.encode(_keyWithMeme()));
    }

    function test_constructorGuards() public {
        vm.expectRevert(bytes("V4_ZERO_ADDR"));
        new UniswapV4NativeViewAdapter(address(this), address(0), address(usdc), 12);
        vm.expectRevert(bytes("V4_SCALE"));
        new UniswapV4NativeViewAdapter(address(this), address(pm), address(usdc), 19);
        vm.expectRevert(BaseAdapter.ZeroRouter.selector);
        new UniswapV4NativeViewAdapter(address(0), address(pm), address(usdc), 12);
    }
}
