// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

interface IUniV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title UniV2GenericAdapter
/// @notice Generic direct-pair swap adapter for ANY standard Uniswap-V2-style constant-product pair,
///         across SEVERAL fork factories pinned at construction. Same idea as UniV3GenericAdapter for
///         V3 forks: ONE deployment serves every pinned V2 fork, so a fork is engine discovery-only
///         once its factory is in the list.
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn to this adapter BEFORE calling
///      swap(); this adapter never transferFrom's the caller and holds no approvals. It then forwards
///      the input to the pair and calls `pair.swap()`, which pays the output DIRECTLY to `to`, so the
///      adapter ends every swap holding zero of both tokens. minAmountOut / deadline / dust-sweep are
///      enforced globally by NullRouter.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived on-chain from pair.token0().
///
///      WHY THIS EXISTS — `UniV2DirectAdapter` (its H1-hardened sibling) pins exactly ONE
///      `immutable FACTORY` and rejects any pool that factory does not claim. That is correct on
///      Monad, where V2 is dead. On Robinhood Chain (4663) the engine routes **eight** V2 factories
///      (`RH_V2_FACTORIES` in engine/src/chain.rs) through a SINGLE `adapter_univ2` config field,
///      emitted unconditionally by math_quoter.rs — so a single-factory adapter there would reject
///      every pool but one fork's. This contract takes the factory LIST instead.
///
///      SECURITY — H1 (2026-08-05 audit) applied to the V2 family. Two independent fixes, matching
///      every hardened Monad adapter:
///        1. `onlyRouter` (BaseAdapter) — before H1 every adapter `swap()` was world-callable, and
///           this one transfers the entire input straight to a caller-named address, so it was a
///           "drain whatever this adapter holds to an address I choose" primitive for anyone.
///        2. PROVENANCE — `pool` must be the pair that a PINNED factory itself returns for
///           (tokenIn, tokenOut). V2's getPair is symmetric, so ONE lookup pins BOTH the pool's
///           authenticity AND its token pair: a caller can no longer name an arbitrary address, nor
///           a real pool of some OTHER pair than the one the router priced and will pay out.
///
///      L4 ASSUMPTION — CANONICAL 0.3% ONLY (inherited verbatim from UniV2DirectAdapter, and it is
///      the reason `feeTiers`-style flexibility is deliberately absent): this adapter hardcodes the
///      canonical Uniswap V2 0.3% swap fee (the 997/1000 factor) and the pure constant-product
///      x*y=k invariant. It will MISPRICE any pair that deviates — a fork with a different fee, a
///      Solidly "stable" pair (x³y+y³x=k), or a fee-on-transfer / rebasing token, where the amount
///      the pair actually receives differs from `amountIn`. Only standard, non-fee-on-transfer 0.3%
///      volatile pairs may be routed here; enforcing that is the ENGINE's job (chain.rs already
///      excludes a 0.5% fork on exactly these grounds). The pair's own `swap()` k-check reverts a
///      too-optimistic `amountOut`, and NullRouter's minAmountOut remains the backstop, but a
///      mispriced quote still costs the user a failed tx or a worse-than-quoted fill.
contract UniV2GenericAdapter is IAdapter, BaseAdapter {
    /// @notice V2 fork factories this adapter accepts pairs from, pinned at deploy.
    /// @dev Written ONLY in the constructor — no setter, no owner — so it is "immutable" in
    ///      substance; a dynamic array cannot use the `immutable` keyword. Adding a fork is a
    ///      redeploy + registry swap, the same cost as any other change to an immutable adapter.
    address[] public factories;

    /// @notice extraData named a pool that no pinned factory claims as the (tokenIn, tokenOut) pair.
    error PoolNotCanonical(address pool);
    /// @notice An empty factory list would brick the adapter — always a deploy-script mistake.
    error EmptyFactoryList();
    /// @notice address(0) in the factory list — always a deploy-script mistake.
    error ZeroFactory();

    constructor(address nullRouter_, address[] memory factories_) BaseAdapter(nullRouter_) {
        if (factories_.length == 0) revert EmptyFactoryList();
        for (uint256 i = 0; i < factories_.length; i++) {
            if (factories_[i] == address(0)) revert ZeroFactory();
            factories.push(factories_[i]);
        }
    }

    /// @notice Number of pinned factories (the array getter alone cannot report length).
    function factoriesLength() external view returns (uint256) {
        return factories.length;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — any canonical 0.3% V2 pair of a pinned fork.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));
        // H1 provenance. Reading token0/getReserves off the pool below is safe only BECAUSE this
        // ran first: a pinned factory, not the pool's own word, is what authenticates it.
        _requireCanonicalPair(pool, tokenIn, tokenOut);
        IUniV2Pair pair = IUniV2Pair(pool);

        // Get reserves
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();

        bool zeroForOne = tokenIn == token0;
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // Calculate amountOut: dy = dx * 997 * reserveOut / (reserveIn * 1000 + dx * 997)
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

        // Transfer tokenIn directly to the pool
        TransferLib.safeTransfer(tokenIn, pool, amountIn);

        // Call swap
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        pair.swap(amount0Out, amount1Out, to, "");
    }

    /// @dev `pool` must be the pair a PINNED factory returns for (tokenA, tokenB). Two registry
    ///      shapes exist across the V2 forks the engine routes on 4663, and both are tried per
    ///      factory (measured on-chain 2026-08-05, chainId asserted):
    ///        · 2-ARG `getPair(address,address)` — canonical UniswapV2Factory. Six of the seven
    ///          pinnable RH forks (uniswap_v2, aeon_v2, swaphood_v2, immutable_lp, rh_v2_d, rh_v2_e).
    ///        · 3-ARG `getPair(address,address,bool stable)` — Solidly/Velodrome-style (giga_v2,
    ///          which has NO 2-arg getPair at all and would otherwise be rejected wholesale).
    ///
    ///      **`stable` is hardcoded FALSE and must stay that way.** A Solidly "stable" pair prices on
    ///      x³y+y³x=k, which the 997/1000 constant-product math above would misprice catastrophically.
    ///      Probing only the volatile slot means such a pair simply fails provenance and is refused —
    ///      the safe outcome, and a real one: giga_v2 has a live stable pair (0x1dd24f42…) today.
    ///
    ///      Every lookup is a STATICCALL whose failure is a NO-MATCH, never a revert of the whole
    ///      swap — a factory that lacks a shape (or reverts on an unknown pair, as some forks do)
    ///      must not veto the factories after it in the list. Trying both shapes cannot weaken the
    ///      check: each returns a DIFFERENT address and only an exact match against `pool` is
    ///      accepted. address(0) is rejected up front so a factory answering "no such pair" with
    ///      zero can never be read as a match.
    function _requireCanonicalPair(address pool, address tokenA, address tokenB) internal view {
        if (pool == address(0)) revert PoolNotCanonical(pool);

        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            address factory = factories[i];
            if (_pairIs(factory, abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB), pool)) {
                return;
            }
            if (
                _pairIs(
                    factory,
                    abi.encodeWithSignature("getPair(address,address,bool)", tokenA, tokenB, false),
                    pool
                )
            ) {
                return;
            }
        }
        revert PoolNotCanonical(pool);
    }

    /// @dev One registry lookup. staticcall, because a factory that lacks the selector — or reverts
    ///      on a pair it does not know — must be a no-match, never a revert of the whole swap.
    function _pairIs(address factory, bytes memory callData, address pool) internal view returns (bool) {
        (bool ok, bytes memory ret) = factory.staticcall(callData);
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == pool;
    }
}
