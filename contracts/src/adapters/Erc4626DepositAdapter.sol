// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @notice The two ERC-4626 functions a deposit needs. `deposit` is declared payable because liquid-staking vaults
///         whose asset is the chain's native coin take it as msg.value (see the adapter NatSpec).
interface IErc4626Deposit {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);
}

interface IWrappedNativeWithdraw {
    function withdraw(uint256 amount) external;
}

/// @title Erc4626DepositAdapter
/// @notice BUY-ONLY venue: turns an ERC-4626 vault's asset into the vault's own share token by calling
///         `deposit` — a mint at the vault's rate, with no pool and no price impact.
/// @dev Why it exists (Monad, 2026-10-12): liquid-staking tokens trade in thin pools but mint without limit.
///      Buying aprMON with 10,000 USD, KyberSwap went WMON -> aprMON through the token's own `deposit` at 0.03 %
///      impact; Chord's only venues were the pools — 3.0 % behind at 5,000 USD and no route under 50 % impact at
///      10,000 USD. At small sizes the pools pay MORE than the mint (the token trades below its rate), so this
///      is one more venue the router compares, not a replacement.
///
///      Two vault flavours, both read on Monad that day:
///        - asset() is an ERC-20 (gMON: asset = WMON): approve the vault, `deposit(assets, receiver)`.
///        - asset() is the native-coin sentinel 0xEeee...EEeE (aprMON, shMON): the vault wants the coin as
///          msg.value EQUAL to `assets` (aprMON reverts `InvalidAmount` without it). The Chord router hands
///          every adapter the WRAPPED coin, so the adapter unwraps first. Only then is tokenIn the wrapped coin.
///      A vault with any other asset for this tokenIn is refused (`AssetMismatch`).
///
///      IMMUTABLE, stateless, PUSH model: the router transfers tokenIn here BEFORE calling swap(). Shares are
///      measured by balance delta and forwarded to `to`; the adapter ends every swap holding nothing.
///
///      extraData = abi.encode(address vault). `vault` MUST equal tokenOut: the token the caller asked to
///      receive IS the contract that gets the deposit, so extraData cannot point the input at a third contract
///      while the route claims another output. There is no registry of ERC-4626 vaults to check against; what
///      bounds a hostile "vault" is that (1) entry is `onlyRouter`, (2) the adapter holds no funds between
///      swaps, (3) the only value it can take is this swap's own input, and the router then enforces the
///      caller's minimum on tokenOut — the token the caller named.
///
///      No redeem / withdraw path: these vaults queue withdrawals (gMON's previewRedeem reverts), so selling a
///      share token stays with the pools.
contract Erc4626DepositAdapter is IAdapter, BaseAdapter {
    /// @notice The address ERC-4626 vaults use for `asset()` when the asset is the chain's native coin.
    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice The chain's wrapped native coin (WMON on Monad) — the form the router delivers native input in.
    address public immutable WRAPPED_NATIVE;

    /// @notice extraData names a vault that is not tokenOut.
    error VaultIsNotTokenOut(address vault, address tokenOut);
    /// @notice The vault's asset is neither tokenIn nor (native coin with tokenIn = wrapped native).
    error AssetMismatch(address asset);
    /// @notice The deposit minted nothing.
    error NoShares();
    /// @notice Native coin arrived from somewhere other than the wrapped-native contract.
    error UnexpectedNative();
    error ZeroAddress();

    constructor(address nullRouter_, address wrappedNative_) BaseAdapter(nullRouter_) {
        if (wrappedNative_ == address(0)) revert ZeroAddress();
        WRAPPED_NATIVE = wrappedNative_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address vault), vault == tokenOut.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata extraData)
        external
        override
        onlyRouter
        returns (uint256 amountOut)
    {
        address vault = abi.decode(extraData, (address));
        if (vault != tokenOut) revert VaultIsNotTokenOut(vault, tokenOut);

        address asset = IErc4626Deposit(vault).asset();
        // Snapshot BEFORE the deposit so the delta below only counts this swap's shares.
        uint256 sharesBefore = IERC20(vault).balanceOf(address(this));

        if (asset == tokenIn) {
            TransferLib.safeApprove(tokenIn, vault, amountIn);
            IErc4626Deposit(vault).deposit(amountIn, address(this));
            TransferLib.safeApprove(tokenIn, vault, 0);
        } else if (asset == NATIVE_ASSET && tokenIn == WRAPPED_NATIVE) {
            IWrappedNativeWithdraw(WRAPPED_NATIVE).withdraw(amountIn);
            IErc4626Deposit(vault).deposit{value: amountIn}(amountIn, address(this));
        } else {
            revert AssetMismatch(asset);
        }

        amountOut = IERC20(vault).balanceOf(address(this)) - sharesBefore;
        if (amountOut == 0) revert NoShares();
        TransferLib.safeTransfer(vault, to, amountOut);

        // A vault that pulled less than amountIn leaves the rest here: it goes to `to` with the shares (the Chord
        // router's dust sweep returns it to the user). The adapter MUST end at zero balance.
        uint256 leftoverIn = IERC20(tokenIn).balanceOf(address(this));
        if (leftoverIn > 0) TransferLib.safeTransfer(tokenIn, to, leftoverIn);
    }

    /// @dev Native coin arrives only from unwrapping (`WRAPPED_NATIVE.withdraw`) inside swap().
    receive() external payable {
        if (msg.sender != WRAPPED_NATIVE) revert UnexpectedNative();
    }
}
