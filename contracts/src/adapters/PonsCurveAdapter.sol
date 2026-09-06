// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {TransferLib} from "../libraries/TransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @dev Pons V2 bonding curve — one contract per launch. Selectors verified on RH mainnet 2026-09-07
///      against curve 0xc779806a… (PENKE): buy = 0x59a87bc1 (payable), sell = 0xd04c6983.
interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
    function isNativeQuote() external view returns (bool);
    function pairToken() external view returns (address);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title PonsCurveAdapter
/// @notice Executes swaps on Pons V2 bonding curves (Robinhood Chain 4663), PRE-graduation.
/// @dev Quote asset is native ETH for most launches (the curve's `isNativeQuote()`), or a
///      factory-approved ERC20 (`pairToken()`, e.g. USDG). NullRouter always hands the adapter
///      ERC20s, so the native side is WETH9 here: buys unwrap WETH → `buy{value}`, sells receive
///      native from the curve → wrap → forward. After graduation the curve reverts `CurveGraduated`
///      and trading moves to a Uniswap V4 pool (Pons Meme hook) that the generic V4 adapter serves.
///
///      H1 provenance: `extraData` names a curve, and a caller-named destination is never trusted on
///      its own word. The FACTORY's launch record for the ROUTE's token must name this very curve:
///      `factory.getLaunchedToken(token)` returns a static struct whose word 1 is the curve
///      (verified on-chain 2026-09-07: getLaunchedToken(PENKE).curve == 0xc779806a…; the same call
///      keyed by a curve address returns all-zero). That is the factory's word, keyed by what the
///      router is pricing — the same shape as a V3 factory `getPool` check. On top, the route is
///      bound to the curve's quote asset (M9): buy = quote in / token out, sell = the reverse.
contract PonsCurveAdapter is IAdapter, BaseAdapter {
    /// @notice Pons V2 launch factory — the ONLY registry this adapter believes about curves.
    address public immutable FACTORY;
    /// @notice WETH9 — the router's ERC20 view of the curve's native quote.
    address public immutable WETH;

    /// @dev `getLaunchedToken(address)` on the factory (4byte + on-chain verified).
    bytes4 private constant GET_LAUNCHED_TOKEN = 0x3cf28b5a;

    /// @notice The factory's launch record for the route's token does not name this curve.
    error CurveNotFromFactory(address curve);
    /// @notice extraData's curve/direction do not match the (tokenIn, tokenOut) the router is pricing.
    error TokenNotBoundToRoute();

    constructor(address nullRouter_, address factory_, address weth_) BaseAdapter(nullRouter_) {
        require(factory_ != address(0) && weth_ != address(0), "PONS_ZERO_ADDR");
        FACTORY = factory_;
        WETH = weth_;
    }

    /// @inheritdoc IAdapter
    /// @dev extraData = abi.encode(address curve, bool isBuy)
    ///      isBuy=true : quote (WETH or pairToken) → curve token
    ///      isBuy=false: curve token → quote
    ///      minOut is 1 on the venue call: NullRouter enforces the user's minOut on the MEASURED
    ///      output (audit M1), and `amountOut` below is that measurement, never the curve's word.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        bytes calldata extraData
    ) external override onlyRouter returns (uint256 amountOut) {
        (address curve, bool isBuy) = abi.decode(extraData, (address, bool));
        address token = isBuy ? tokenOut : tokenIn;
        if (curveOf(token) != curve) revert CurveNotFromFactory(curve);

        bool nativeQuote = IPonsCurve(curve).isNativeQuote();
        address quoteToken = nativeQuote ? WETH : IPonsCurve(curve).pairToken();
        bool bound = isBuy
            ? (tokenIn == quoteToken && tokenOut == token)
            : (tokenIn == token && tokenOut == quoteToken);
        if (!bound || quoteToken == address(0)) revert TokenNotBoundToRoute();

        if (isBuy) {
            uint256 before = IERC20(token).balanceOf(to);
            if (nativeQuote) {
                IWETH9(WETH).withdraw(amountIn);
                IPonsCurve(curve).buy{value: amountIn}(amountIn, 1, to);
            } else {
                TransferLib.safeApprove(quoteToken, curve, amountIn);
                IPonsCurve(curve).buy(amountIn, 1, to);
                TransferLib.safeApprove(quoteToken, curve, 0);
            }
            amountOut = IERC20(token).balanceOf(to) - before;
            // A buy that finishes the curve (graduation runs inside it) may hand back unused quote.
            // This contract is immutable and ownerless: never strand it — return it to `to`
            // (NullRouter dust-sweeps extra tokenIn back to the user).
            _forwardResidual(quoteToken, nativeQuote, to);
        } else {
            TransferLib.safeApprove(token, curve, amountIn);
            if (nativeQuote) {
                uint256 balBefore = address(this).balance;
                IPonsCurve(curve).sell(amountIn, 1, address(this));
                amountOut = address(this).balance - balBefore;
                TransferLib.safeApprove(token, curve, 0);
                // Wrap + forward the ENTIRE native balance while reporting only this swap's
                // proceeds — over-reporting is what M1 punishes, extra WETH is just swept.
                _forwardResidual(WETH, true, to);
            } else {
                uint256 balBefore = IERC20(quoteToken).balanceOf(to);
                IPonsCurve(curve).sell(amountIn, 1, to);
                amountOut = IERC20(quoteToken).balanceOf(to) - balBefore;
                TransferLib.safeApprove(token, curve, 0);
            }
        }
    }

    /// @notice The curve the factory recorded for `token` (address(0) = no such launch).
    /// @dev Low-level staticcall on purpose: the full launch struct is not part of the published
    ///      ABI, but its layout is static (word 0 = token, word 1 = curve) — a dynamic struct would
    ///      begin with an offset word (0x20), and it does not.
    function curveOf(address token) public view returns (address) {
        (bool ok, bytes memory ret) = FACTORY.staticcall(abi.encodeWithSelector(GET_LAUNCHED_TOKEN, token));
        if (!ok || ret.length < 64) return address(0);
        uint256 word1;
        assembly {
            word1 := mload(add(ret, 64))
        }
        if (word1 >> 160 != 0) return address(0); // not an address-shaped word → not the struct we expect
        return address(uint160(word1));
    }

    /// @dev Never leave quote on this immutable, ownerless adapter: wrap (native) and forward it all.
    function _forwardResidual(address quoteToken, bool nativeQuote, address to) internal {
        if (nativeQuote) {
            uint256 bal = address(this).balance;
            if (bal > 0) {
                IWETH9(WETH).deposit{value: bal}();
                TransferLib.safeTransfer(WETH, to, bal);
            }
        } else {
            uint256 bal = IERC20(quoteToken).balanceOf(address(this));
            if (bal > 0) TransferLib.safeTransfer(quoteToken, to, bal);
        }
    }

    /// @dev Accept native ETH from WETH9.withdraw() and from the curve's sell payout / buy refund.
    receive() external payable {}
}
