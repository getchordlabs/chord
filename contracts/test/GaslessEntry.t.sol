// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {GaslessEntry} from "../src/GaslessEntry.sol";

/// Real OZ ERC20Permit so the EIP-2612 flow is exercised end-to-end.
contract PermitToken is ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _x(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "ALLOWANCE"); allowance[f][msg.sender] = al - a; }
        _x(f, to, a); return true;
    }
    function _x(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "BAL"); balanceOf[f] -= a; balanceOf[to] += a; }
}

contract MockWMON is MockERC20 {
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "WMON_BAL");
        balanceOf[msg.sender] -= a;
        (bool ok, ) = msg.sender.call{value: a}("");
        require(ok, "WMON_SEND");
    }
    receive() external payable {}
}

contract MockRegistry { function isApproved(address) external pure returns (bool) { return true; } }
contract MockFeeCollector {
    function feeBps() external pure returns (uint16) { return 5; }
    function feeBpsFor(address) external pure returns (uint16) { return 5; }
    function collectFee(address, uint256, address) external {}
}

/// Mints `amountIn` of tokenOut 1:1 to `to` (18-dec outputs for WMON, 6-dec in = tiny out —
/// tests use OUT tokens with the same scale as amounts passed).
contract MockAdapter {
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

contract GaslessEntryTest is Test {
    NullRouter router;
    GaslessEntry entry;
    PermitToken usdc;
    MockERC20 tB;
    MockWMON wmon;
    address _adp;

    uint256 constant USER_PK = 0xA11CE;
    address user;
    address relayer = address(0xCAFE);

    uint128 constant AMT = 100e6; // 100 USDC
    uint256 constant OUT = uint256(AMT); // adapter mints 1:1
    uint256 constant OUT_AFTER_FEE = OUT - (OUT * 5) / 10_000;

    function setUp() public {
        user = vm.addr(USER_PK);
        usdc = new PermitToken();
        tB = new MockERC20();
        wmon = new MockWMON();
        MockFeeCollector fc = new MockFeeCollector();
        MockRegistry reg = new MockRegistry();
        _adp = address(new MockAdapter());

        NullRouter impl = new NullRouter();
        bytes memory initData = abi.encodeCall(
            NullRouter.initialize,
            (address(this), address(wmon), address(0), address(fc), address(reg))
        );
        router = NullRouter(payable(address(new ERC1967Proxy(address(impl), initData))));

        entry = new GaslessEntry(address(router), address(wmon), address(this));
        entry.setRelayer(relayer, true);

        vm.deal(address(wmon), 1_000_000 ether);
        usdc.mint(user, 1_000e6);
        // user has ZERO native — the whole point
        vm.deal(user, 0);
    }

    // ---- helpers ----

    function _order(address tokenOut, uint256 minOut, uint256 fee) internal view returns (GaslessEntry.GaslessOrder memory) {
        return GaslessEntry.GaslessOrder({
            user: user,
            tokenIn: address(usdc),
            tokenOut: tokenOut,
            amountIn: AMT,
            minAmountOut: minOut,
            relayerFee: fee,
            deadline: block.timestamp + 600,
            nonce: entry.nonces(user)
        });
    }

    function _signOrder(GaslessEntry.GaslessOrder memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, entry.orderDigest(o));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 value) internal view returns (GaslessEntry.PermitData memory) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            user, address(entry), value, usdc.nonces(user), block.timestamp + 600
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, digest);
        return GaslessEntry.PermitData({ value: value, deadline: block.timestamp + 600, v: v, r: r, s: s });
    }

    function _routes1(address tin, address tout) internal view returns (INullRouter.RouteStep[] memory r) {
        r = new INullRouter.RouteStep[](1);
        r[0] = INullRouter.RouteStep({adapter: _adp, tokenIn: tin, tokenOut: tout, amountIn: AMT, extraData: ""});
    }

    // ---- happy paths ----

    function test_gasless_erc20Out() public {
        uint256 fee = 1e6; // 1 USDC-worth of tB
        GaslessEntry.GaslessOrder memory o = _order(address(tB), OUT_AFTER_FEE - fee, fee);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);

        vm.prank(relayer);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));

        assertEq(tB.balanceOf(user), OUT_AFTER_FEE - fee, "user gets output minus exact fee");
        assertEq(tB.balanceOf(relayer), fee, "relayer gets exact fee");
        assertEq(usdc.balanceOf(user), 1_000e6 - AMT, "input consumed");
        assertEq(entry.nonces(user), 1, "nonce bumped");
    }

    function test_gasless_nativeOut_userGetsGasMoney() public {
        uint256 fee = 0.5 ether;
        GaslessEntry.GaslessOrder memory o = _order(address(0), OUT_AFTER_FEE * 1e12 - fee, fee);
        // adapter mints WMON 1:1 with 6-dec input → scale: mint AMT units of WMON… use raw math:
        // route delivers AMT (=100e6) WMON-wei — too small vs fee. Use a fee sized to raw out.
        o.minAmountOut = OUT_AFTER_FEE - 1e6;
        o.relayerFee = 1e6;
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);

        uint256 balBefore = user.balance;
        vm.prank(relayer);
        entry.execute(o, sig, p, _routes1(address(usdc), address(wmon)), GaslessEntry.RouteKind.Single, address(0));

        assertEq(user.balance - balBefore, OUT_AFTER_FEE - 1e6, "user received native MON (gas money!)");
        assertEq(address(relayer).balance, 1e6, "relayer fee in native");
        assertEq(address(entry).balance, 0, "no native stuck");
    }

    function test_gasless_worksWithZeroFee() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), OUT_AFTER_FEE, 0);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(relayer);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
        assertEq(tB.balanceOf(user), OUT_AFTER_FEE);
    }

    // ---- security ----

    function test_revert_notRelayer() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 1, 0);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(address(0xBAD));
        vm.expectRevert(GaslessEntry.NotRelayer.selector);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
    }

    function test_revert_badSignature() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 1, 0);
        bytes memory sig = _signOrder(o);
        o.minAmountOut = 0; // tamper AFTER signing
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(relayer);
        vm.expectRevert(GaslessEntry.BadSignature.selector);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
    }

    function test_revert_replay() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 1, 0);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(type(uint256).max);
        vm.startPrank(relayer);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
        vm.expectRevert(GaslessEntry.BadNonce.selector);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
        vm.stopPrank();
    }

    function test_revert_expired() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 1, 0);
        o.deadline = block.timestamp - 1;
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(relayer);
        vm.expectRevert(GaslessEntry.Expired.selector);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
    }

    function test_revert_relayerCannotInflateFee() public {
        // Router mints OUT; floor(minOut)+fee must be ≤ OUT_AFTER_FEE. A greedy
        // relayer can't take more than the SIGNED fee — the fee isn't an input,
        // it's in the signed order; tampering = BadSignature (covered above).
        // Here: user floor high enough that fee+floor > delivered → revert.
        GaslessEntry.GaslessOrder memory o = _order(address(tB), OUT_AFTER_FEE, 1); // floor + 1 wei fee > delivered
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(relayer);
        vm.expectRevert(); // router InsufficientOutput
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
    }

    function test_surplus_goesToUser() public {
        // Floor well below delivered: user gets ALL surplus, relayer only exact fee.
        uint256 fee = 2e6;
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 10e6, fee);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        vm.prank(relayer);
        entry.execute(o, sig, p, _routes1(address(usdc), address(tB)), GaslessEntry.RouteKind.Single, address(0));
        assertEq(tB.balanceOf(user), OUT_AFTER_FEE - fee, "surplus to user");
        assertEq(tB.balanceOf(relayer), fee, "relayer capped at signed fee");
    }

    function test_multiHop_pinning() public {
        GaslessEntry.GaslessOrder memory o = _order(address(tB), 1, 0);
        bytes memory sig = _signOrder(o);
        GaslessEntry.PermitData memory p = _permit(AMT);
        INullRouter.RouteStep[] memory r = new INullRouter.RouteStep[](2);
        r[0] = INullRouter.RouteStep({adapter: _adp, tokenIn: address(wmon), tokenOut: address(wmon), amountIn: AMT, extraData: ""}); // wrong entry
        r[1] = INullRouter.RouteStep({adapter: _adp, tokenIn: address(wmon), tokenOut: address(tB), amountIn: 0, extraData: ""});
        vm.prank(relayer);
        vm.expectRevert(GaslessEntry.InvalidRoutePlan.selector);
        entry.execute(o, sig, p, r, GaslessEntry.RouteKind.MultiHop, address(0));
    }

    function test_receive_rejectsStrayNative() public {
        vm.deal(address(0xABCD), 1 ether);
        vm.prank(address(0xABCD));
        (bool ok, ) = address(entry).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
