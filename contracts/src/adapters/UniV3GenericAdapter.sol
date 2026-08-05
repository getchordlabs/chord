// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter, PoolProvenance} from "./BaseAdapter.sol";

interface IUniV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev exactInput when amountSpecified > 0. Returns pool-perspective deltas:
    ///      positive = pool received (input owed), negative = pool paid (output).
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title UniV3GenericAdapter
/// @notice Generic direct-pool swap adapter for ANY standard Uniswap-V3-style concentrated-liquidity
///         pool — Uniswap V3, PancakeSwap V3, Pangolin V3, MondayTrade, Pinot, Noxa, Algebra, … . There
///         is NO per-fork SwapRouter: the swap EXECUTES DIRECTLY on the pool via pool.swap() and settles
///         the input token inside the swap callback. ONE deployment serves every current + future V3
///         fork, so a new fork becomes engine discovery-only (no new contract, no new deploy).
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn to this adapter BEFORE calling
///      swap(); this adapter NEVER transferFrom's the caller and holds no approvals. The pool pays the
///      output DIRECTLY to `to` (swap recipient), so the adapter ends every swap holding zero of both
///      tokens. minAmountOut / deadline / dust-sweep are enforced globally by NullRouter.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived on-chain from pool.token0().
///
///      SECURITY — callback gate via TRANSIENT storage (cancun): the pool being swapped is tstore'd
///      immediately before pool.swap and cleared the instant it returns. The swap callback requires
///      msg.sender == the tload'd pool, so it is invokable ONLY by the pool this adapter is actively
///      swapping on, and only within that transaction; outside a swap the slot reads zero and any stray
///      call reverts ("V3_BAD_CALLBACK"). Fork callbacks use DIFFERENT selectors
///      (uniswapV3SwapCallback / pancakeV3SwapCallback / algebraSwapCallback) but share the identical
///      (int256 amount0Delta, int256 amount1Delta, bytes data) ABI, so the named Uniswap callback covers
///      Uniswap-style forks and a `fallback` covers the rest — both settle through one path.
///
///      SECURITY — H1 (2026-08-05 audit): the callback gate above pins WHICH contract may call back,
///      not THAT it is a real pool. Since `pool` came from caller-supplied extraData, a hostile
///      "pool" armed the gate to itself and then named both the token and the amount in `_settle` —
///      the sharpest primitive in the report. Two independent fixes now: `onlyRouter` (BaseAdapter)
///      and CREATE2 PROVENANCE below — the pool must be the canonical CREATE2 address for its own
///      (token0, token1, fee) under one of the fork factories pinned at construction.
contract UniV3GenericAdapter is IAdapter, BaseAdapter {
    /// @dev Uniswap V3 sqrt-price bounds. Passing (MIN+1) for zeroForOne / (MAX-1) otherwise means
    ///      "no price limit" → the pool swaps the full exact-input amount.
    uint160 internal constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    /// @notice Transient slot holding the pool allowed to invoke the swap callback (zero outside swaps).
    bytes32 private constant EXPECTED_POOL_TSLOT = keccak256("nullterminal.univ3-generic.expected-pool");

    /// @notice Fork factories this adapter accepts pools from, and each fork's pool INIT_CODE_HASH.
    /// @dev Parallel arrays, written ONLY in the constructor (no setter, no owner) — "immutable" in
    ///      substance; dynamic arrays cannot use the `immutable` keyword. ONE adapter still serves
    ///      every V3 fork (that is the whole point of this contract), but a new fork now needs its
    ///      (factory, initCodeHash) entry, so it becomes a redeploy instead of discovery-only.
    ///
    ///      initCodeHash semantics — read this before deploying:
    ///      · NON-ZERO → CREATE2 derivation, no external call. The hash DIFFERS per fork and is
    ///        supplied by the deploy script from a VERIFIED value; a wrong hash makes every swap on
    ///        that fork revert (caught by the mandatory both-ways mainnet verification).
    ///      · ZERO → the fork's own on-chain REGISTRY is consulted instead (getPool / poolByPair on
    ///        the pinned factory). Equally authoritative — the factory is pinned either way — and it
    ///        is the honest option when a fork's creation-code hash cannot be verified. NEVER guess a
    ///        hash to avoid the external call; pass zero.
    address[] public factories;
    bytes32[] public initCodeHashes;

    /// @notice Candidate CREATION fee tiers to probe when a pool's CURRENT `fee()` is not its key.
    /// @dev DYNAMIC-FEE FORKS ARE REAL, measured on Monad 2026-08-05: PangolinV3 pool
    ///      0xcd00A33B…97A5 (AUSD/WMON) answers `fee() == 10` today but the factory registered it —
    ///      and salted its address — under **2500**. Deriving provenance from the pool's live fee
    ///      therefore fails for exactly the fork this adapter exists to serve. The creation fee is not
    ///      recoverable from the pool, so the deploy script pins the small set of tiers the engine
    ///      actually discovers (100/500/2500/3000/10000 on Monad) and they are probed after the live
    ///      fee. Probing extra tiers cannot weaken anything: each one derives/looks up a DIFFERENT
    ///      address, and only an exact match against `pool` is accepted.
    uint24[] public feeTiers;

    /// @notice extraData named a pool no pinned factory can be shown to have created.
    error PoolNotCanonical(address pool);
    error FactoryListMismatch();

    constructor(
        address nullRouter_,
        address[] memory factories_,
        bytes32[] memory initCodeHashes_,
        uint24[] memory feeTiers_
    ) BaseAdapter(nullRouter_) {
        if (factories_.length == 0 || factories_.length != initCodeHashes_.length) {
            revert FactoryListMismatch();
        }
        for (uint256 i = 0; i < factories_.length; i++) {
            require(factories_[i] != address(0), "V3_ZERO_FACTORY");
            factories.push(factories_[i]);
            initCodeHashes.push(initCodeHashes_[i]);
        }
        for (uint256 i = 0; i < feeTiers_.length; i++) {
            feeTiers.push(feeTiers_[i]);
        }
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — any standard V3-style pool of a pinned fork.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        // A too-large amountIn would wrap to a negative int256 → the pool would read it as an
        // exact-OUTPUT swap. Reject it (NullRouter never sends anywhere near this).
        require(amountIn <= uint256(type(int256).max), "V3_AMOUNT_OVERFLOW");
        address pool = abi.decode(extraData, (address));

        address token0 = IUniV3PoolMinimal(pool).token0();
        address token1 = IUniV3PoolMinimal(pool).token1();
        // H1 provenance: the pool must derive from a pinned factory. Reading token0/token1 off the
        // pool is safe HERE and only here — the CREATE2 match, not the pool's word, authenticates it.
        _requireCanonicalPool(pool, token0, token1);

        bool zeroForOne = tokenIn == token0;
        // Bind the router's economics to the pool's actual pair: without this a caller could name a
        // real pool whose tokenOut is a different asset than the one the router prices and pays out.
        require(
            zeroForOne ? tokenOut == token1 : (tokenIn == token1 && tokenOut == token0),
            "V3_PAIR_MISMATCH"
        );

        bytes32 tslot = EXPECTED_POOL_TSLOT;
        assembly {
            tstore(tslot, pool)
        }
        // recipient = `to`: the pool pays the output straight to the final receiver.
        (int256 amount0, int256 amount1) = IUniV3PoolMinimal(pool).swap(
            to,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1,
            abi.encode(tokenIn)
        );
        assembly {
            tstore(tslot, 0)
        }

        // Output = the token the pool PAID (its negative delta).
        int256 outDelta = zeroForOne ? amount1 : amount0;
        require(outDelta < 0, "V3_NO_OUTPUT");
        amountOut = uint256(-outDelta);

        // M5: a thin fork pool can exhaust its liquidity and terminate early — the callback then pays
        // only what it consumed and the remainder is stranded on an IMMUTABLE, OWNERLESS adapter with
        // no rescue. Sweep it to `to` (always NullRouter, whose dust-sweep returns it to the user),
        // mirroring LfjPoeAdapter. Chosen over `require(full consumption)` because a partial fill that
        // still clears the user's minAmountOut is a legitimate fill — reverting it would turn a
        // liquidity condition into a failed transaction the user still pays gas for.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @dev H1: `pool` must be provably created by one of the pinned fork factories, for exactly this
    ///      token pair. Two shapes exist across V3 forks and both are tried per factory:
    ///      · PAIR-KEYED (dynamic-fee / Algebra-style): salt = keccak(token0, token1), or the
    ///        factory's `poolByPair` registry.
    ///      · FEE-KEYED (Uniswap-style): salt = keccak(token0, token1, fee), or `getPool(t0,t1,fee)`.
    ///      For the fee-keyed shape the CREATION fee is what matters and it is NOT always the pool's
    ///      current `fee()` (see `feeTiers` — PangolinV3 on Monad reports 10, was created at 2500), so
    ///      the live fee is tried first and the pinned candidate tiers after. Trying extra shapes or
    ///      tiers cannot weaken the check: each derives/looks up a different address and only an exact
    ///      match against `pool` is accepted.
    function _requireCanonicalPool(address pool, address token0, address token1) internal view {
        uint256 n = factories.length;

        // Pass 1 — pair-keyed shapes (no fee involved at all).
        bytes32 saltNoFee = keccak256(abi.encode(token0, token1));
        for (uint256 i = 0; i < n; i++) {
            bytes32 initCodeHash = initCodeHashes[i];
            if (initCodeHash != bytes32(0)) {
                if (PoolProvenance.computeAddress(factories[i], initCodeHash, saltNoFee) == pool) return;
            } else if (_poolByPairSays(factories[i], token0, token1, pool)) {
                return;
            }
        }

        // Pass 2 — fee-keyed shapes: the pool's live fee first, then the pinned creation-fee tiers.
        // fee() does not exist on every fork; a failed call simply means the live fee is unknown.
        uint24 liveFee = 0;
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("fee()"));
        if (ok && ret.length >= 32) {
            liveFee = uint24(abi.decode(ret, (uint256)));
            if (_feeKeyedMatch(pool, token0, token1, liveFee)) return;
        }
        uint256 m = feeTiers.length;
        for (uint256 k = 0; k < m; k++) {
            uint24 candidate = feeTiers[k];
            if (candidate == liveFee) continue; // already tried
            if (_feeKeyedMatch(pool, token0, token1, candidate)) return;
        }

        revert PoolNotCanonical(pool);
    }

    /// @dev Fee-keyed provenance across every pinned factory, for ONE candidate fee.
    function _feeKeyedMatch(address pool, address token0, address token1, uint24 fee)
        internal
        view
        returns (bool)
    {
        bytes32 salt = keccak256(abi.encode(token0, token1, fee));
        uint256 n = factories.length;
        for (uint256 i = 0; i < n; i++) {
            bytes32 initCodeHash = initCodeHashes[i];
            if (initCodeHash != bytes32(0)) {
                if (PoolProvenance.computeAddress(factories[i], initCodeHash, salt) == pool) return true;
            } else {
                (bool ok, bytes memory ret) = factories[i].staticcall(
                    abi.encodeWithSignature("getPool(address,address,uint24)", token0, token1, fee)
                );
                if (ok && ret.length >= 32 && abi.decode(ret, (address)) == pool) return true;
            }
        }
        return false;
    }

    /// @dev Algebra-style registry lookup. staticcall, because a factory that lacks the selector must
    ///      be a no-match — never a revert of the whole swap.
    function _poolByPairSays(address factory, address token0, address token1, address pool)
        internal
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) = factory.staticcall(
            abi.encodeWithSignature("poolByPair(address,address)", token0, token1)
        );
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == pool;
    }

    /// @notice Uniswap V3 swap callback — pays the pool the input it is owed. Uniswap-style forks
    ///         (incl. Pangolin, MondayTrade) call this selector directly.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _settle(amount0Delta, amount1Delta, data);
    }

    /// @notice Callback for V3 forks whose callback uses a DIFFERENT selector (e.g. pancakeV3SwapCallback,
    ///         algebraSwapCallback) but the identical (int256,int256,bytes) ABI. Routed here via fallback.
    fallback() external {
        (int256 amount0Delta, int256 amount1Delta, bytes memory data) =
            abi.decode(msg.data[4:], (int256, int256, bytes));
        _settle(amount0Delta, amount1Delta, data);
    }

    /// @dev Shared settlement: gate to the active pool, then push the OWED input (positive delta) to it.
    function _settle(int256 amount0Delta, int256 amount1Delta, bytes memory data) private {
        bytes32 tslot = EXPECTED_POOL_TSLOT;
        address expected;
        assembly {
            expected := tload(tslot)
        }
        require(expected != address(0) && msg.sender == expected, "V3_BAD_CALLBACK");

        // Exactly one delta is positive (the input the pool is owed). data = abi.encode(tokenIn).
        address tokenIn = abi.decode(data, (address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        require(owed > 0, "V3_NOTHING_OWED");
        TransferLib.safeTransfer(tokenIn, msg.sender, owed);
    }
}
