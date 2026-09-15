// Calls every read tool once against the live API and prints one line each — the check to run
// before publishing or after an API change. `pnpm smoke`.
import { runTool } from "./tools.js";

const line = (name: string, v: unknown) => console.log(name.padEnd(20), JSON.stringify(v).slice(0, 160));
const ov: any = await runTool("chord_overview", {}); line("chord_overview", { swaps: ov.last24h?.swaps, venues: ov.venues24h?.length });
const s: any = await runTool("chord_search_tokens", { query: "nv" }); line("chord_search_tokens", s.matches?.slice(0, 3).map((m: any) => m.symbol));
const p: any = await runTool("chord_price", { token: "NVDA" }); line("chord_price", { price: p.priceUsd, chg: p.change24hPct });
const st: any = await runTool("chord_stocks", { limit: 3 }); line("chord_stocks", st.rows?.map((r: any) => [r.symbol, r.afterHoursSharePct7d]));
const one: any = await runTool("chord_stock", { token: "SPY" }); line("chord_stock", { price: one.priceUsd, pools: one.pools24h?.length, h24: one.windows?.h24?.txns });
const q: any = await runTool("chord_quote", { tokenIn: "ETH", tokenOut: "NVDA", amount: "0.1" }); line("chord_quote", { out: q.amountOut, impact: q.priceImpactPct, route: q.route?.map((r: any) => r.dex) });
const sm: any = await runTool("chord_smart_money", { window: "7d", limit: 3 }); line("chord_smart_money", sm.wallets?.map((w: any) => [w.wallet.slice(0, 8), w.pnlUsd]));
const pnl: any = await runTool("chord_wallet_pnl", { wallet: "0x12414068aa4e85fe1ff6fe3781c48f97028add3a" }); line("chord_wallet_pnl", { realized: pnl.realizedUsd, tokens: pnl.tokens?.length });
console.log("ok");
const ao: any = await runTool("chord_arc_overview", {}); line("chord_arc_overview", { swaps: ao.last24h?.swaps, venues: ao.venues24h?.length });
const at: any = await runTool("chord_arc_tokens", { limit: 3 }); line("chord_arc_tokens", at.rows?.map((r: any) => [r.symbol, r.volume24hUsd]));
if (at.rows?.[0]) { const a1: any = await runTool("chord_arc_token", { address: at.rows[0].address, hours: 24 }); line("chord_arc_token", { sym: a1.token?.symbol, hours: a1.series?.length, pools: a1.pools?.length }); }
const av: any = await runTool("chord_arc_venues", { days: 7 }); line("chord_arc_venues", av.venues?.map((v: any) => [v.dex, v.sharePct]));
