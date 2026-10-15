// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NullRouter} from "../src/NullRouter.sol";
import {INullRouter} from "../src/interfaces/INullRouter.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";

// ROUND 13 — the first fuzz/invariant tests in this repo.
//
// Twelve rounds of example-based tests share one blind spot: they only catch bugs someone already
// imagined. foundry.toml has had `fuzz = { runs = 256 }` configured the whole time with nothing
// using it. Here the machine picks the inputs — and for the stateful part, the whole SEQUENCE of
// calls — and we assert properties that must hold for every one of them.

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

contract MockFeeCollector {
    uint16 public bps = 5;
    function setBps(uint16 b) external { bps = b; }
    function feeBps() external view returns (uint16) { return bps; }
    function feeBpsFor(address) external view returns (uint16) { return bps; }
    function referralShareBps() external pure returns (uint16) { return 5000; }
    function collectFee(address, uint256, address) external {}
}

/// Delivers a caller-set percentage of the input, so the fuzzer can drive both the
/// meets-minOut and the falls-short branch.
contract RatioAdapter {
    uint256 public pct = 100;
    function setPct(uint256 p) external { pct = p; }
    function swap(address, address tokenOut, uint256 amountIn, address to, bytes calldata) external returns (uint256) {
        uint256 out = (amountIn * pct) / 100;
        MockERC20(tokenOut).mint(to, out);
        return out;
    }
}

contract NullRouterFuzzTest is Test {
    NullRouter router;
    AdapterRegistry registry;
    MockERC20 tA;
    MockERC20 tB;
    MockFeeCollector fc;
    RatioAdapter adapter;
    address user = address(0xBEEF);

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        MockERC20 wmon = new MockERC20();
        fc = new MockFeeCollector();
        adapter = new RatioAdapter();

        AdapterRegistry regImpl = new AdapterRegistry();
        registry = AdapterRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(AdapterRegistry.initialize, (address(this)))))
        );
        registry.addAdapter(address(adapter));

        NullRouter impl = new NullRouter();
        router = NullRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            NullRouter.initialize,
                            (address(this), address(wmon), address(0), address(fc), address(registry))
                        )
                    )
                )
            )
        );

        tA.mint(user, type(uint128).max);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _step(uint256 amountIn) internal view returns (INullRouter.RouteStep memory) {
        return INullRouter.RouteStep({
            adapter: address(adapter),
            tokenIn: address(tA),
            tokenOut: address(tB),
            amountIn: amountIn,
            extraData: ""
        });
    }

    // ── G1/G3/G4: the money math, for every amount / fee / slippage the fuzzer picks ──
    function testFuzz_userNeverReceivesLessThanMinOut(uint128 rawAmount, uint16 rawFeeBps, uint256 rawMinOut) public {
        uint256 amountIn = bound(uint256(rawAmount), 1, type(uint96).max);
        uint16 feeBps = uint16(bound(uint256(rawFeeBps), 0, 100)); // FeeCollector's own hard cap
        fc.setBps(feeBps);

        uint256 grossOut = amountIn; // the 1:1 adapter
        uint256 fee = (grossOut * feeBps) / 10_000;
        uint256 afterFee = grossOut - fee;
        uint256 minOut = bound(rawMinOut, 0, grossOut * 2); // deliberately reaches above what is achievable

        uint256 before = tB.balanceOf(user);
        vm.prank(user);
        if (minOut > afterFee) {
            // G4: a shortfall must ALWAYS revert. Never a quiet partial fill.
            vm.expectRevert();
            router.swap(address(tA), address(tB), amountIn, minOut, block.timestamp + 60, _step(amountIn), address(0));
            assertEq(tB.balanceOf(user), before, "a reverted swap must not move tokens");
        } else {
            router.swap(address(tA), address(tB), amountIn, minOut, block.timestamp + 60, _step(amountIn), address(0));
            uint256 received = tB.balanceOf(user) - before;
            assertGe(received, minOut, "G1: received less than the signed minimum");
            assertEq(received, afterFee, "G3: the user must get exactly output minus the fee");
            assertLe(fee, grossOut, "G3: fee cannot exceed the output");
        }
    }

    // ── G2: the router is a pipe, not a wallet ──────────────────────────────────────
    function testFuzz_routerRetainsNothing(uint128 rawAmount, uint16 rawFeeBps, uint8 rawPct) public {
        uint256 amountIn = bound(uint256(rawAmount), 1, type(uint96).max);
        fc.setBps(uint16(bound(uint256(rawFeeBps), 0, 100)));
        adapter.setPct(bound(uint256(rawPct), 1, 100)); // adapter may underdeliver

        vm.prank(user);
        try router.swap(address(tA), address(tB), amountIn, 0, block.timestamp + 60, _step(amountIn), address(0)) {
            // success path
        } catch {
            // revert path is fine — the assertion below must hold either way
        }
        assertEq(tA.balanceOf(address(router)), 0, "G2: router kept input tokens");
        assertEq(tB.balanceOf(address(router)), 0, "G2: router kept output tokens");
    }

    // ── Deadline, for any timestamp the fuzzer picks ────────────────────────────────
    function testFuzz_expiredDeadlineAlwaysReverts(uint32 nowTs, uint32 past) public {
        uint256 t = bound(uint256(nowTs), 1_000_000, type(uint32).max);
        vm.warp(t);
        uint256 deadline = t - bound(uint256(past), 1, 999_999);
        vm.prank(user);
        vm.expectRevert();
        router.swap(address(tA), address(tB), 1 ether, 0, deadline, _step(1 ether), address(0));
    }
}

// ── G5: stateful — the property must survive any SEQUENCE the fuzzer builds ─────────
contract RouterHandler is Test {
    NullRouter public router;
    MockERC20 public tA;
    MockERC20 public tB;
    MockFeeCollector public fc;
    RatioAdapter public adapter;
    address public user;
    uint256 public swapCount;

    constructor(NullRouter r, MockERC20 a, MockERC20 b, MockFeeCollector f, RatioAdapter ad, address u) {
        router = r; tA = a; tB = b; fc = f; adapter = ad; user = u;
    }

    /// The fuzzer calls this with random parameters, in random order, as many times as it likes.
    function swap(uint128 rawAmount, uint16 rawFee, uint8 rawPct, uint256 rawMinOut) external {
        uint256 amountIn = bound(uint256(rawAmount), 1, 1_000_000 ether);
        fc.setBps(uint16(bound(uint256(rawFee), 0, 100)));
        adapter.setPct(bound(uint256(rawPct), 1, 100));
        uint256 minOut = bound(rawMinOut, 0, amountIn);

        INullRouter.RouteStep memory step = INullRouter.RouteStep({
            adapter: address(adapter),
            tokenIn: address(tA),
            tokenOut: address(tB),
            amountIn: amountIn,
            extraData: ""
        });
        vm.prank(user);
        try router.swap(address(tA), address(tB), amountIn, minOut, block.timestamp + 3600, step, address(0)) {
            swapCount++;
        } catch {}
    }
}

contract NullRouterInvariantTest is StdInvariant, Test {
    NullRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockFeeCollector fc;
    RatioAdapter adapter;
    RouterHandler handler;
    address user = address(0xBEEF);

    function setUp() public {
        tA = new MockERC20();
        tB = new MockERC20();
        MockERC20 wmon = new MockERC20();
        fc = new MockFeeCollector();
        adapter = new RatioAdapter();

        AdapterRegistry regImpl = new AdapterRegistry();
        AdapterRegistry registry = AdapterRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(AdapterRegistry.initialize, (address(this)))))
        );
        registry.addAdapter(address(adapter));

        NullRouter impl = new NullRouter();
        router = NullRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            NullRouter.initialize,
                            (address(this), address(wmon), address(0), address(fc), address(registry))
                        )
                    )
                )
            )
        );

        tA.mint(user, type(uint128).max);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);

        handler = new RouterHandler(router, tA, tB, fc, adapter, user);
        targetContract(address(handler));
    }

    /// After ANY sequence of swaps — succeeded, reverted, any fee, any adapter shortfall — the
    /// router must be holding nothing. A leak that only shows up on the 7th call in a particular
    /// order is exactly what example-based tests miss.
    function invariant_routerNeverAccumulatesTokens() public view {
        assertEq(tA.balanceOf(address(router)), 0, "router accumulated input tokens across calls");
        assertEq(tB.balanceOf(address(router)), 0, "router accumulated output tokens across calls");
    }
}
