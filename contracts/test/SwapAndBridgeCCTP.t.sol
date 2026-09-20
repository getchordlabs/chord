// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SwapAndBridgeCCTP } from "../src/SwapAndBridgeCCTP.sol";

contract MintableERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev A router stand-in: pulls `amountIn` of tokenIn (or takes msg.value) and pays `rate` USDC per unit to msg.sender.
contract MockRouter {
    MintableERC20 public usdc;
    uint256 public payout; // USDC paid on the next call, set by the test
    bool public shouldRevert;
    constructor(MintableERC20 u) { usdc = u; }
    function set(uint256 p, bool r) external { payout = p; shouldRevert = r; }
    function swap(address tokenIn, uint256 amountIn) external payable {
        if (shouldRevert) revert("router says no");
        if (tokenIn != address(0)) IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        usdc.mint(msg.sender, payout);
    }
}

contract MockMessenger {
    struct Burn { uint256 amount; uint32 domain; bytes32 recipient; address token; uint256 maxFee; uint32 finality; address from; }
    Burn public last;
    uint256 public calls;
    function depositForBurn(uint256 amount, uint32 domain, bytes32 recipient, address token, bytes32, uint256 maxFee, uint32 finality) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount); // real messenger burns from the caller's allowance
        last = Burn(amount, domain, recipient, token, maxFee, finality, msg.sender);
        calls++;
    }
}

contract SwapAndBridgeCCTPTest is Test {
    MintableERC20 usdc;
    MintableERC20 mon;
    MockRouter router;
    MockMessenger messenger;
    SwapAndBridgeCCTP sab;
    address user = address(0xBEEF);
    address fees = address(0xFEE5);
    bytes32 recipient = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        usdc = new MintableERC20("USDC", "USDC", 6);
        mon = new MintableERC20("WMON", "WMON", 18);
        router = new MockRouter(usdc);
        messenger = new MockMessenger();
        sab = new SwapAndBridgeCCTP(address(router), address(usdc), address(messenger), fees, 10); // 10 bps
        mon.mint(user, 1000e18);
        vm.deal(user, 100 ether);
        vm.prank(user);
        mon.approve(address(sab), type(uint256).max);
    }

    function _swapData(address tokenIn, uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockRouter.swap.selector, tokenIn, amountIn);
    }

    function test_swapAndBurn_erc20_takesFee_burnsRest() public {
        router.set(1_000_000_000, false); // 1,000 USDC out
        vm.prank(user);
        uint256 burned = sab.swapAndBurn(address(mon), 100e18, _swapData(address(mon), 100e18), 999_000_000, 26, recipient, 325_000);
        assertEq(burned, 999_000_000, "10 bps off 1,000 USDC");
        assertEq(usdc.balanceOf(fees), 1_000_000, "fee to recipient");
        assertEq(usdc.balanceOf(address(sab)), 0, "nothing left behind");
        (uint256 amount, uint32 domain, bytes32 rcpt, address token, uint256 maxFee, uint32 finality, address from) = messenger.last();
        assertEq(amount, 999_000_000);
        assertEq(domain, 26);
        assertEq(rcpt, recipient);
        assertEq(token, address(usdc));
        assertEq(maxFee, 325_000);
        assertEq(finality, 1000, "fast transfer");
        assertEq(from, address(sab));
        assertEq(mon.allowance(address(sab), address(router)), 0, "router allowance reset");
    }

    function test_swapAndBurn_native() public {
        router.set(50_000_000, false);
        vm.prank(user);
        uint256 burned = sab.swapAndBurn{ value: 1 ether }(address(0), 1 ether, _swapData(address(0), 1 ether), 50_000_000, 26, recipient, 0);
        assertEq(burned, 49_950_000);
        assertEq(messenger.calls(), 1);
    }

    function test_revert_whenSwapUnderDelivers() public {
        router.set(990_000_000, false); // router pays 990 but the user agreed to ≥ 999
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SwapAndBridgeCCTP.InsufficientOutput.selector, 990_000_000, 999_000_000));
        sab.swapAndBurn(address(mon), 100e18, _swapData(address(mon), 100e18), 999_000_000, 26, recipient, 0);
        assertEq(messenger.calls(), 0, "nothing burned");
    }

    function test_revert_routerFailure_bubblesReason() public {
        router.set(0, true);
        vm.prank(user);
        vm.expectRevert();
        sab.swapAndBurn(address(mon), 100e18, _swapData(address(mon), 100e18), 1, 26, recipient, 0);
        assertEq(mon.balanceOf(user), 1000e18, "tokens stay with the user on revert");
    }

    function test_revert_nativeValueMismatch() public {
        vm.prank(user);
        vm.expectRevert(SwapAndBridgeCCTP.BadValue.selector);
        sab.swapAndBurn{ value: 0.5 ether }(address(0), 1 ether, _swapData(address(0), 1 ether), 1, 26, recipient, 0);
        vm.prank(user);
        vm.expectRevert(SwapAndBridgeCCTP.BadValue.selector);
        sab.swapAndBurn{ value: 1 ether }(address(mon), 1e18, _swapData(address(mon), 1e18), 1, 26, recipient, 0);
    }

    function test_burn_only_takesFee() public {
        usdc.mint(user, 20_000_000);
        vm.prank(user);
        usdc.approve(address(sab), 20_000_000);
        vm.prank(user);
        uint256 burned = sab.burn(20_000_000, 26, recipient, 0);
        assertEq(burned, 19_980_000);
        assertEq(usdc.balanceOf(fees), 20_000);
    }

    function test_revert_feeExceedsAmount() public {
        usdc.mint(user, 100);
        vm.prank(user);
        usdc.approve(address(sab), 100);
        vm.prank(user);
        vm.expectRevert(SwapAndBridgeCCTP.NothingToBurn.selector);
        sab.burn(100, 26, recipient, 100); // Circle's maxFee ≥ the whole amount
    }

    function test_constructor_capsFee() public {
        vm.expectRevert(SwapAndBridgeCCTP.FeeTooHigh.selector);
        new SwapAndBridgeCCTP(address(router), address(usdc), address(messenger), fees, 101);
        // zero fee needs no recipient
        SwapAndBridgeCCTP free = new SwapAndBridgeCCTP(address(router), address(usdc), address(messenger), address(0), 0);
        assertEq(free.FEE_BPS(), 0);
    }

    function test_rejectsStrayNative() public {
        vm.prank(user);
        (bool ok, ) = address(sab).call{ value: 1 }("");
        assertFalse(ok);
    }
}
