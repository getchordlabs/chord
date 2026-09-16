// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title TaxProbe / TaxScratch — measure a token's transfer tax through eth_call state overrides
/// @notice NEVER deployed. The engine puts `TaxProbe`'s runtime code at a V2 PAIR's address and
///         `TaxScratch`'s at a scratch address via the `eth_call` state-override parameter, then calls
///         `probe(token)` on the pair. Running AS the pair means the probe holds the pair's real token
///         balance and `msg.sender == pair` for every transfer, so tax logic keyed on the pair address
///         (the common "tax when the counterparty is the AMM" pattern) sees exactly what a swap sees.
///           · pair → scratch: what a BUYER receives per unit the pair sends (buyRecvBps);
///           · scratch → pair: what the PAIR receives per unit a SELLER sends (sellRecvBps).
///         Both in bps of the amount sent; 10_000 = no tax. The amount is 1/1000 of the pair's holding
///         (min 1 wei) so the probe never trips max-tx-amount limits.
/// @dev Arc (5042) V2 official-factory tokens measured 2026-09-16: 401K, Big, 0xadb2…, 0x9012… all
///      1–2 % — the engine haircuts its x·y=k quote by these and the tax-safe adapter executes on the
///      pair's ACTUAL received amount (docs/arc-contracts-deploy.md §6).
interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract TaxScratch {
    function send(address token, address to, uint256 amount) external {
        IERC20Min(token).transfer(to, amount);
    }
}

contract TaxProbe {
    function probe(address token, address scratch) external returns (uint256 buyRecvBps, uint256 sellRecvBps) {
        IERC20Min t = IERC20Min(token);
        uint256 amount = t.balanceOf(address(this)) / 1000;
        if (amount == 0) amount = 1;
        uint256 s0 = t.balanceOf(scratch);
        t.transfer(scratch, amount);
        uint256 recv = t.balanceOf(scratch) - s0;
        buyRecvBps = (recv * 10_000) / amount;
        if (recv == 0) return (buyRecvBps, 0);
        uint256 p0 = t.balanceOf(address(this));
        TaxScratch(scratch).send(token, address(this), recv);
        uint256 back = t.balanceOf(address(this)) - p0;
        sellRecvBps = (back * 10_000) / recv;
    }
}
