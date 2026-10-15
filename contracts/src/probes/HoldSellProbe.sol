// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HoldSellProbe — can a buyer's wallet actually hold a token and sell it LATER? (eth_simulateV1 overrides)
/// @notice NEVER deployed. The engine puts this code at a scratch address and runs two simulated blocks
///         (eth_simulateV1) from a CODE-LESS wallet W with a native balance override:
///           block n+1  W → probe.buy{value}(…, W)   wrap, hop to the pair's anchor if needed, buy with a REAL
///                                                   pair.swap() to this contract, then hand the tokens to W
///                                                   (the router → wallet hop of a real buy)
///                      W → token.approve(probe, max)
///           block n+k  W → probe.sell(…)            read what W holds, pull it to the probe with transferFrom
///                                                   and push it to the pair (a router's sell), pay the anchor to W
///         Why (2026-10-02, BNB): a one-call buy-and-sell probe (SwapTaxProbe, removed) passed tokens a holder cannot get
///         out of. Measured with this probe: three honeypots buy fine and the wallet's later sell pays nothing; 奶龙
///         0x99332d02 refuses the held wallet's sell ("g"; through ChordRouter: TransferFromFailed). The 空龙抗狼康 scam
///         0x36ee9ec6 even passes here — its owner resets buyers a few blocks later, which no simulation sees — but
///         `buy` returns the never-used wallet's balance BEFORE the buy, and that token shows 9e9 at every address.
///         A step a token blocks reverts that call; the engine reads every call's status, never one number.
interface IERC20H {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWrappedH {
    function deposit() external payable;
}

interface IPairH {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IFactoryH {
    function getPair(address, address) external view returns (address);
}

contract HoldSellProbe {
    /// What the pair sent on the buy, what this contract handed to the wallet, and what balanceOf said the fresh
    /// wallet held before (block n+1 → read in the later block).
    uint256 private sentByPair;
    uint256 private handed;
    uint256 private walletBefore;

    /// Buy `token` on `pair` with msg.value of native, then hand everything received to `wallet`. Returns (what the
    /// pair sent, what this contract received and handed on, balanceOf(wallet) BEFORE the buy). A never-used wallet
    /// with a non-zero balance is a fake ledger: 空龙抗狼康 0x36ee9ec6 shows 9,000,000,000 at every address, and its
    /// owner's contract (0x839d0bd2…, selector 0x5e86c2ca) put the real buyer's balance back to that 7–27 blocks after
    /// the buy — an owner action no simulation can foresee, but the fake baseline is visible before anyone buys.
    function buy(address factory, address pair, address token, address wrapped, uint256 feeBps, address wallet)
        external
        payable
        returns (uint256 sent, uint256 received, uint256 before)
    {
        before = IERC20H(token).balanceOf(wallet);
        walletBefore = before;
        IWrappedH(wrapped).deposit{value: msg.value}();
        address anchor = _other(pair, token);
        uint256 anchorAmt = msg.value;
        if (anchor != wrapped) {
            address hop = IFactoryH(factory).getPair(wrapped, anchor);
            require(hop != address(0), "no hop");
            (, anchorAmt) = _swap(hop, wrapped, anchor, anchorAmt, feeBps, address(this));
        }
        (sent, received) = _swap(pair, anchor, token, anchorAmt, feeBps, address(this));
        require(sent > 0 && received > 0, "no out");
        IERC20H(token).transfer(wallet, received);
        sentByPair = sent;
        handed = received;
    }

    /// Called by the wallet in a LATER block, in the shape of a real router sell: pull the wallet's tokens to this
    /// contract (transferFrom, like ChordRouter), then push them to the pair and swap the anchor to the wallet — a
    /// direct wallet → pair transfer is refused by some memes (奶龙 0x99332d02 reverts "g") that sell fine through
    /// a router. heldBps = what the wallet holds (above its pre-buy balance) per unit the pair sent, capped;
    /// sellRecvBps = what the pair received per unit pulled from the wallet; got / expected = anchor paid to the
    /// wallet / the untaxed x·y=k output for the amount pulled.
    function sell(address pair, address token, uint256 feeBps)
        external
        returns (uint256 heldBps, uint256 sellRecvBps, uint256 got, uint256 expected)
    {
        address wallet = msg.sender;
        uint256 sent = sentByPair;
        require(sent > 0, "no buy");
        uint256 seen = IERC20H(token).balanceOf(wallet);
        uint256 held = seen > walletBefore ? seen - walletBefore : 0;
        heldBps = held >= sent * 10 ? 100_000 : (held * 10_000) / sent;
        uint256 amt = held < handed ? held : handed;
        require(amt > 0, "held 0");
        address anchor = _other(pair, token);
        bool tokenIs0 = IPairH(pair).token0() == token;
        (uint112 r0, uint112 r1,) = IPairH(pair).getReserves();
        (uint256 rIn, uint256 rOut) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        expected = _out(amt, rIn, rOut, feeBps);
        uint256 p0 = IERC20H(token).balanceOf(address(this));
        IERC20H(token).transferFrom(wallet, address(this), amt);
        uint256 pulled = IERC20H(token).balanceOf(address(this)) - p0;
        require(pulled > 0, "pulled 0");
        IERC20H(token).transfer(pair, pulled);
        // Reserves again AFTER the push (Router02's fee-on-transfer order): a token that swaps its own fee balance
        // inside transfer() moves them (SI 0xfa5c30eb: pricing on the pre-push reserves failed Pancake's K check).
        (r0, r1,) = IPairH(pair).getReserves();
        (rIn, rOut) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 recvd = IERC20H(token).balanceOf(pair) - rIn;
        sellRecvBps = (recvd * 10_000) / amt;
        uint256 out = _out(recvd, rIn, rOut, feeBps);
        require(out > 0, "no out");
        uint256 b0 = IERC20H(anchor).balanceOf(wallet);
        (uint256 a0, uint256 a1) = tokenIs0 ? (uint256(0), out) : (out, uint256(0));
        IPairH(pair).swap(a0, a1, wallet, "");
        got = IERC20H(anchor).balanceOf(wallet) - b0;
    }

    function _other(address pair, address token) internal view returns (address) {
        address t0 = IPairH(pair).token0();
        return t0 == token ? IPairH(pair).token1() : t0;
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut, uint256 feeBps) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * (10_000 - feeBps);
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    /// Push `amountIn` of `tIn`, price what the pair actually received (x·y=k at `feeBps`), swap to `to`.
    /// Returns (what the pair sent, what `to` received).
    function _swap(address pair, address tIn, address tOut, uint256 amountIn, uint256 feeBps, address to)
        internal
        returns (uint256 sent, uint256 received)
    {
        bool inIs0 = IPairH(pair).token0() == tIn;
        IERC20H(tIn).transfer(pair, amountIn);
        (uint112 r0, uint112 r1,) = IPairH(pair).getReserves();
        (uint256 rIn, uint256 rOut) = inIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        sent = _out(IERC20H(tIn).balanceOf(pair) - rIn, rIn, rOut, feeBps);
        uint256 b0 = IERC20H(tOut).balanceOf(to);
        (uint256 a0, uint256 a1) = inIs0 ? (uint256(0), sent) : (sent, uint256(0));
        IPairH(pair).swap(a0, a1, to, "");
        received = IERC20H(tOut).balanceOf(to) - b0;
    }
}
