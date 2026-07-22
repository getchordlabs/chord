// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LFJ POE OraclePool — there is NO router swap path; swaps execute DIRECTLY on the pool
///         with a callback settlement. Selectors verified on Monad mainnet bytecode 2026-07-22:
///         swap 0x80c2c6ef, swapCallback 0xfa483e72.
interface ILfjPoePool {
    function getTokens() external view returns (address tokenX, address tokenY);

    /// @notice Exact-in swap. Settlement order: the pool transfers the OUTPUT to `recipient`
    ///         FIRST, then calls swapCallback on msg.sender, which must PUSH the input token to
    ///         the pool (the pool NEVER calls transferFrom — no approvals anywhere). Deltas are
    ///         pool-perspective: positive = pool receives (the input owed), negative = pool paid.
    ///         Partial fills owe only the positive delta (actualAmountIn), not amountIn.
    function swap(
        address recipient,
        bool swapXtoY,
        uint256 amountIn,
        bytes calldata data
    ) external returns (int256 deltaX, int256 deltaY);
}

/// @title LfjPoeAdapter
/// @notice Executes exact-in swaps directly on LFJ POE OraclePools (callback settlement).
/// @dev IMMUTABLE, stateless. PUSH model: NullRouter transfers tokenIn here BEFORE calling swap();
///      this adapter never transferFrom's the caller. Output is measured by balance delta and
///      forwarded to `to`; the adapter ends every swap with ZERO balance of tokenIn and tokenOut.
///
///      extraData = abi.encode(address pool) ONLY. Direction is derived ON-CHAIN from the pool's
///      getTokens() (swapXtoY = tokenIn == tokenX) — nothing market-specific is pinned, which is
///      also why there is NO constructor: the pool arrives per-swap and the venue has no shared
///      router/vault to cross-check, so a stateless-empty adapter is the honest shape.
///
///      Settlement: pool pays output to this adapter FIRST, then invokes swapCallback here; the
///      callback pushes exactly the POSITIVE delta (= actualAmountIn; partial fills owe only that)
///      of the input token to the pool via transfer and returns 0xfa483e72. The pool balance-checks
///      itself — underpay reverts Callback__InsufficientTokenReceived. NO approvals anywhere.
///
///      SECURITY — callback gating via TRANSIENT storage (cancun): the expected pool address is
///      tstore'd immediately before pool.swap and cleared right after it returns. swapCallback
///      requires msg.sender == the tload'd address, so it is callable ONLY by the pool this
///      adapter is actively swapping on, only within that transaction ("POE_BAD_CALLBACK" for
///      strangers, including any direct call outside a swap — the slot reads zero then).
///
///      Partial fills: the callback pays only the positive delta; the input remainder stays on
///      this adapter and is forwarded to `to` after the output (router dust-sweep returns it to
///      the user on single-hop).
///
///      ERC20/WMON-only: NullRouter wraps MON->WMON before any ERC20 adapter and the pool settles
///      strictly in its two ERC20 tokens — no native handling, no receive().
contract LfjPoeAdapter is IAdapter {
    /// @notice Transient slot holding the pool allowed to invoke swapCallback (zero outside swaps).
    bytes32 private constant EXPECTED_POOL_TSLOT = keccak256("nullterminal.lfj-poe.expected-pool");

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address pool) — the POE OraclePool.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(extraData, (address));

        (address tokenX, address tokenY) = ILfjPoePool(pool).getTokens();

        bool swapXtoY;
        if (tokenIn == tokenX && tokenOut == tokenY) {
            swapXtoY = true;
        } else if (tokenIn == tokenY && tokenOut == tokenX) {
            swapXtoY = false;
        } else {
            revert("POE_PAIR_MISMATCH");
        }

        // Snapshot BEFORE the venue call so the delta below only counts this swap's proceeds.
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // Arm the callback gate for exactly this pool, for exactly this call.
        bytes32 tslot = EXPECTED_POOL_TSLOT;
        assembly {
            tstore(tslot, pool)
        }
        ILfjPoePool(pool).swap(address(this), swapXtoY, amountIn, "");
        assembly {
            tstore(tslot, 0)
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut > 0, "POE_NO_FILL");
        TransferLib.safeTransfer(tokenOut, to, amountOut);

        // Partial-fill remainder (callback paid only the positive delta) -> back to `to`; the
        // router's dust-sweep returns it to the user on single-hop. Adapter ends at zero balance.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) {
            TransferLib.safeTransfer(tokenIn, to, leftoverIn);
        }
    }

    /// @notice POE settlement callback — pays the pool the input it is owed.
    /// @dev Callable ONLY by the pool this adapter is actively swapping on (transient-storage
    ///      gate). Deltas are pool-perspective; the POSITIVE one is the input token/amount owed.
    ///      Pays exactly that (partial fills owe less than amountIn) and returns the required
    ///      magic (this function's own selector, 0xfa483e72).
    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata) external returns (bytes4) {
        bytes32 tslot = EXPECTED_POOL_TSLOT;
        address expected;
        assembly {
            expected := tload(tslot)
        }
        require(msg.sender == expected, "POE_BAD_CALLBACK");

        (address tokenX, address tokenY) = ILfjPoePool(msg.sender).getTokens();
        if (deltaX > 0) {
            TransferLib.safeTransfer(tokenX, msg.sender, uint256(deltaX));
        } else {
            require(deltaY > 0, "POE_BAD_DELTA");
            TransferLib.safeTransfer(tokenY, msg.sender, uint256(deltaY));
        }
        return this.swapCallback.selector;
    }
}
