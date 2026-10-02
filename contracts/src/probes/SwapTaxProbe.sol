// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title SwapTaxProbe — measure a token's transfer tax through a REAL pair.swap(), via eth_call overrides
/// @notice NEVER deployed. The engine's fallback when `TaxProbe` (which runs AS the pair and transfers out
///         directly) reverts. Many BNB meme tokens refuse any transfer out of their pair that is not part
///         of a swap — they read it as liquidity removal ("b", "撤池" guards) — so the transfer probe left
///         tokens like 奶龙 (0x99332d02…, $31M/24h; router buy + injected-balance sell simulations pass — not proof) unquoted
///         (2026-10-02). This probe sits at a scratch address with a NATIVE balance override and:
///           1. wraps `nativeIn` (deposit — no storage-slot knowledge needed);
///           2. if the pair's other side is not the wrapped native, buys it on factory.getPair(wrapped, anchor);
///           3. BUYS `token` with a real pair.swap() → buyRecvBps = received / what the pair sent;
///           4. sends the tokens back to the pair → sellRecvBps = what the pair received / what was sent.
///         Both in bps; 10_000 = no tax. A token that blocks a step reverts the call = unquoted (the caller
///         treats a revert as "unmeasurable"), exactly like the transfer probe.
/// @dev NOT SUFFICIENT ON ITS OWN (2026-10-02): buying and selling inside one call cannot see a token that keeps
///      the buyer's tokens after the router → wallet hop — 空龙抗狼康 0x36ee9ec6 read 9999 / 10000 here and a real
///      buy left the wallet holding 0. The engine (decide_tax) never routes on this reading alone; it needs a
///      code-less wallet that holds the tokens and sells them in a later block (eth_simulateV1, not built yet).
interface IERC20P {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IWrappedP {
    function deposit() external payable;
}

interface IPairP {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IFactoryP {
    function getPair(address, address) external view returns (address);
}

contract SwapTaxProbe {
    function probe(address factory, address pair, address token, address wrapped, uint256 nativeIn, uint256 feeBps)
        external
        returns (uint256 buyRecvBps, uint256 sellRecvBps)
    {
        IWrappedP(wrapped).deposit{value: nativeIn}();
        address t0 = IPairP(pair).token0();
        address anchor = t0 == token ? IPairP(pair).token1() : t0;
        uint256 anchorAmt = nativeIn;
        if (anchor != wrapped) {
            address hop = IFactoryP(factory).getPair(wrapped, anchor);
            require(hop != address(0), "no hop");
            (, anchorAmt) = _swap(hop, wrapped, anchor, nativeIn, feeBps);
        }
        (uint256 sent, uint256 recv) = _swap(pair, anchor, token, anchorAmt, feeBps);
        require(sent > 0, "no out");
        buyRecvBps = (recv * 10_000) / sent;
        if (recv == 0) return (buyRecvBps, 0);
        uint256 p0 = IERC20P(token).balanceOf(pair);
        IERC20P(token).transfer(pair, recv);
        sellRecvBps = ((IERC20P(token).balanceOf(pair) - p0) * 10_000) / recv;
    }

    /// Push `amountIn` of `tIn`, price what the pair actually received (x·y=k at `feeBps`), swap to this
    /// contract. Returns (what the pair sent, what this contract received).
    function _swap(address pair, address tIn, address tOut, uint256 amountIn, uint256 feeBps)
        internal
        returns (uint256 sent, uint256 received)
    {
        bool inIs0 = IPairP(pair).token0() == tIn;
        IERC20P(tIn).transfer(pair, amountIn);
        (uint112 r0, uint112 r1,) = IPairP(pair).getReserves();
        (uint256 rIn, uint256 rOut) = inIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 got = IERC20P(tIn).balanceOf(pair) - rIn;
        uint256 inWithFee = got * (10_000 - feeBps);
        sent = (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
        uint256 b0 = IERC20P(tOut).balanceOf(address(this));
        (uint256 a0, uint256 a1) = inIs0 ? (uint256(0), sent) : (sent, uint256(0));
        IPairP(pair).swap(a0, a1, address(this), "");
        received = IERC20P(tOut).balanceOf(address(this)) - b0;
    }
}
