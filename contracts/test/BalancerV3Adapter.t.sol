// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerV3Adapter} from "../src/adapters/BalancerV3Adapter.sol";

/// Minimal ERC20 for the mock flow.
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

/// Mock AggregatorRouter: settles a pre-funded swap. Asserts the Vault was paid up front, then credits
/// tokenOut to the SENDER (the adapter) — exactly how the real router's _vault.sendTo(sender, ...) works.
contract MockAggregatorRouter {
    address public immutable VAULT;
    uint256 public rate; // amountOut = amountIn * rate / 1e18
    constructor(address vault_, uint256 rate_) { VAULT = vault_; rate = rate_; }

    function swapSingleTokenExactIn(
        address, // pool
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        uint256, // minAmountOut
        uint256, // deadline
        bytes calldata // userData
    ) external returns (uint256 amountOut) {
        // The adapter must have pre-funded the Vault with exactAmountIn before calling.
        require(MockERC20(tokenIn).balanceOf(VAULT) >= exactAmountIn, "NOT_PREFUNDED");
        amountOut = (exactAmountIn * rate) / 1e18;
        // Credit output to the caller (the adapter), like _vault.sendTo(sender, tokenOut, amountOut).
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}

contract BalancerV3AdapterTest is Test {
    BalancerV3Adapter adapter;
    MockAggregatorRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address vault = address(0xBA11);
    address recipient = address(0xDEAD);
    address pool = address(0x2DAA);

    function setUp() public {
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        router = new MockAggregatorRouter(vault, 0.99e18); // 0.99 out per 1 in
        adapter = new BalancerV3Adapter(vault, address(router));
    }

    function test_swap_prefundsVault_and_forwardsOutput() public {
        uint256 amountIn = 1_000e6;
        // NullRouter PUSH model: tokens are sent to the adapter before swap() is called.
        tokenIn.mint(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            recipient,
            abi.encode(pool)
        );

        assertEq(amountOut, 990e6, "amountOut");
        // Vault was paid up front (mock router asserts NOT_PREFUNDED otherwise).
        assertEq(tokenIn.balanceOf(vault), amountIn, "vault prefunded");
        // Output forwarded to the recipient, none stuck in the adapter.
        assertEq(tokenOut.balanceOf(recipient), 990e6, "recipient got output");
        assertEq(tokenOut.balanceOf(address(adapter)), 0, "no output stuck in adapter");
        assertEq(tokenIn.balanceOf(address(adapter)), 0, "no input stuck in adapter");
    }

    function test_swap_revertsIfNotPrefunded() public {
        // No mint to the adapter → safeTransfer to the Vault will fail (insufficient balance).
        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e6, recipient, abi.encode(pool));
    }

    function test_decode_extraData_isPoolAddress() public {
        tokenIn.mint(address(adapter), 1e6);
        // A correct abi.encode(address) must decode cleanly and run.
        adapter.swap(address(tokenIn), address(tokenOut), 1e6, recipient, abi.encode(pool));
        assertEq(tokenOut.balanceOf(recipient), 0.99e6, "decoded + swapped");
    }
}
