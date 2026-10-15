// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalancerV3BoostedAdapter, IBalancerAggregatorBatchRouter} from "../src/adapters/BalancerV3BoostedAdapter.sol";

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

/// Mock Vault: the two registry views the boosted adapter consults for per-step H1 provenance.
contract MockVault {
    mapping(address => bool) public isPoolRegistered;
    mapping(address => bool) public isERC4626BufferInitialized;
    function register(address pool) external { isPoolRegistered[pool] = true; }
    function registerBuffer(address wrapped) external { isERC4626BufferInitialized[wrapped] = true; }
}

/// Mock AggregatorBatchRouter: settles a pre-funded multi-step swap. Asserts the Vault was paid up front,
/// reads tokenIn/exactAmountIn from the path + the final tokenOut from the last step, and credits the
/// output to the SENDER (the adapter) — like the real router's _vault.sendTo(sender, ...).
contract MockAggregatorBatchRouter {
    address public immutable VAULT;
    uint256 public rate; // out = in * rate / 1e18
    constructor(address vault_, uint256 rate_) { VAULT = vault_; rate = rate_; }
    function getVault() external view returns (address) { return VAULT; }

    function swapExactIn(IBalancerAggregatorBatchRouter.SwapPathExactAmountIn[] memory paths, uint256, bytes calldata)
        external
        returns (uint256[] memory pathAmountsOut, address[] memory tokensOut, uint256[] memory amountsOut)
    {
        IBalancerAggregatorBatchRouter.SwapPathExactAmountIn memory p = paths[0];
        require(MockERC20(p.tokenIn).balanceOf(VAULT) >= p.exactAmountIn, "NOT_PREFUNDED");
        address finalOut = p.steps[p.steps.length - 1].tokenOut;
        uint256 out = (p.exactAmountIn * rate) / 1e18;
        MockERC20(finalOut).mint(msg.sender, out);
        pathAmountsOut = new uint256[](1); pathAmountsOut[0] = out;
        tokensOut = new address[](1); tokensOut[0] = finalOut;
        amountsOut = new uint256[](1); amountsOut[0] = out;
    }
}

contract BalancerV3BoostedAdapterTest is Test {
    BalancerV3BoostedAdapter adapter;
    MockAggregatorBatchRouter router;
    MockERC20 usdc;   // raw in
    MockERC20 usdt0;  // raw out
    address vault;
    address recipient = address(0xDEAD);
    address pool = address(0x2DAA);
    address wnUSDC = address(0x1111);
    address wnUSDT0 = address(0x2222);

    function setUp() public {
        usdc = new MockERC20();
        usdt0 = new MockERC20();
        MockVault v = new MockVault();
        v.register(pool);
        v.registerBuffer(wnUSDC);
        v.registerBuffer(wnUSDT0);
        vault = address(v);
        router = new MockAggregatorBatchRouter(vault, 1.001e18); // ~1:1 stable
        // H1: the test contract stands in for NullRouter — adapters are now onlyRouter.
        adapter = new BalancerV3BoostedAdapter(address(this), vault, address(router));
    }

    function _steps() internal view returns (bytes memory) {
        IBalancerAggregatorBatchRouter.SwapPathStep[] memory steps = new IBalancerAggregatorBatchRouter.SwapPathStep[](3);
        steps[0] = IBalancerAggregatorBatchRouter.SwapPathStep({ pool: wnUSDC, tokenOut: wnUSDC, isBuffer: true });
        steps[1] = IBalancerAggregatorBatchRouter.SwapPathStep({ pool: pool, tokenOut: wnUSDT0, isBuffer: false });
        steps[2] = IBalancerAggregatorBatchRouter.SwapPathStep({ pool: wnUSDT0, tokenOut: address(usdt0), isBuffer: true });
        return abi.encode(steps);
    }

    function test_boostedSwap_prefundsVault_decodesPath_forwardsOutput() public {
        uint256 amountIn = 1_000e6;
        usdc.mint(address(adapter), amountIn); // NullRouter PUSH

        uint256 amountOut = adapter.swap(address(usdc), address(usdt0), amountIn, recipient, _steps());

        assertEq(amountOut, 1001e6, "amountOut (1.001x)");
        assertEq(usdc.balanceOf(vault), amountIn, "vault prefunded");
        assertEq(usdt0.balanceOf(recipient), 1001e6, "recipient got output");
        assertEq(usdt0.balanceOf(address(adapter)), 0, "nothing stuck in adapter");
    }

    function test_revertsIfNotPrefunded() public {
        vm.expectRevert();
        adapter.swap(address(usdc), address(usdt0), 1_000e6, recipient, _steps());
    }
}
