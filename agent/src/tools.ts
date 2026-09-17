// Chord agent harness — the tools, framework-agnostic. Each tool is a name, a description an LLM can
// read, a zod input schema, and a handler that calls the Chord API and returns compact JSON. mcp.ts
// exposes them over the Model Context Protocol; manifest.ts prints them as function-calling schemas
// for OpenAI-style tool use. Everything is a read except chord_swap_tx, which returns an UNSIGNED
// transaction — signing stays in the agent's own wallet, Chord never holds keys or funds.
import { z } from "zod";

export const CHAIN = 4663;
const BASE = (process.env.CHORD_API_URL || "https://api.getchord.xyz").replace(/\/+$/, "");
const KEY = process.env.CHORD_API_KEY || "";
const NATIVE = "0x0000000000000000000000000000000000000000";

type Token = { address: string; symbol: string; name: string; decimals: number; tags?: string[]; logoURI?: string };
let tokenCache: { at: number; list: Token[] } | null = null;

async function api<T = any>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { Accept: "application/json", ...(init?.body ? { "Content-Type": "application/json" } : {}), ...(KEY ? { "X-API-Key": KEY } : {}), ...(init?.headers || {}) },
  });
  const text = await r.text();
  let body: any; try { body = JSON.parse(text); } catch { body = { raw: text }; }
  if (!r.ok) throw new Error(`Chord API ${r.status} ${path}: ${body?.error || body?.message || text.slice(0, 200)}`);
  return body as T;
}

export async function tokenList(): Promise<Token[]> {
  if (tokenCache && Date.now() - tokenCache.at < 5 * 60_000) return tokenCache.list;
  const d = await api<any>(`/v1/tokens?chain=${CHAIN}`);
  const list: Token[] = Array.isArray(d) ? d : d.tokens ?? [];
  tokenCache = { at: Date.now(), list };
  return list;
}

/** Resolve "NVDA", "usdg", "eth" or a 0x address to a listed token. */
export async function resolveToken(q: string): Promise<Token> {
  const list = await tokenList();
  const s = q.trim().toLowerCase();
  if (s === "eth" || s === NATIVE) return { address: NATIVE, symbol: "ETH", name: "Ether", decimals: 18 };
  const hit = list.find((t) => t.address.toLowerCase() === s) ?? list.find((t) => t.symbol.toLowerCase() === s) ?? list.find((t) => t.name.toLowerCase() === s);
  if (!hit) throw new Error(`No listed token on chain ${CHAIN} matches "${q}". Try chord_search_tokens.`);
  return hit;
}

const toRaw = (amount: string, decimals: number): string => {
  const [i, f = ""] = amount.trim().split(".");
  const frac = (f + "0".repeat(decimals)).slice(0, decimals);
  return (BigInt(i || "0") * 10n ** BigInt(decimals) + BigInt(frac || "0")).toString();
};
const fromRaw = (raw: string, decimals: number): string => {
  const v = BigInt(raw); const d = 10n ** BigInt(decimals);
  const whole = v / d; const frac = (v % d).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac.slice(0, 8)}` : whole.toString();
};
const slim = (t: Token) => ({ address: t.address, symbol: t.symbol, name: t.name.replace(/\s*•\s*Robinhood Token$/i, ""), decimals: t.decimals, stock: !!t.tags?.includes("stock") });

export interface Tool<I extends z.ZodTypeAny = z.ZodTypeAny> {
  name: string;
  description: string;
  input: I;
  run: (args: z.infer<I>) => Promise<unknown>;
}
const tool = <I extends z.ZodTypeAny>(t: Tool<I>) => t;

export const tools = [
  tool({
    name: "chord_overview",
    description: `What the Chord index holds right now on chain ${CHAIN}: 24h volume, swap count, tokens traded, and the venues with their share. Use first to orient.`,
    input: z.object({}),
    run: async () => {
      const d = await api<any>("/v1/rh/overview");
      return { chain: d.chain, last24h: d.last24h, venues24h: (d.venues24h ?? []).map((v: any) => ({ dex: v.dex, volUsd: Math.round(v.volUsd), trades: v.trades, sharePct: +v.sharePct.toFixed(2) })), updatedAt: d.updatedAt };
    },
  }),
  tool({
    name: "chord_search_tokens",
    description: `Find listed tokens on chain ${CHAIN} by symbol, name or address. Returns up to 10 matches with addresses and whether each is a tokenized stock.`,
    input: z.object({ query: z.string().min(1).describe("Symbol, name fragment, or 0x address") }),
    run: async ({ query }) => {
      const s = query.trim().toLowerCase(); const list = await tokenList();
      const scored = list.map((t) => { const sym = t.symbol.toLowerCase(), name = t.name.toLowerCase();
        const sc = t.address.toLowerCase() === s ? 6 : sym === s ? 5 : sym.startsWith(s) ? 4 : name.startsWith(s) ? 3 : sym.includes(s) ? 2 : name.includes(s) ? 1 : 0; return [sc, t] as const; })
        .filter(([sc]) => sc > 0).sort((a, b) => b[0] - a[0]).slice(0, 10);
      return { matches: scored.map(([, t]) => slim(t)) };
    },
  }),
  tool({
    name: "chord_price",
    description: "Live price, 24h change, 24h volume and trade count for one token, from Chord's own index of on-chain trades.",
    input: z.object({ token: z.string().describe("Symbol like NVDA or USDG, or a 0x address") }),
    run: async ({ token }) => {
      const t = await resolveToken(token);
      const m = await api<any>(`/v1/tokens/market?chain=${CHAIN}`);
      const row = m.market?.[t.address.toLowerCase()] ?? null;
      return { token: slim(t), priceUsd: row?.priceUsd ?? null, change24hPct: row?.change24h ?? null, volume24hUsd: row?.volume24h ?? null, trades24h: row?.txns24h ?? null, liquidityUsd: row?.liquidityUsd ?? null };
    },
  }),
  tool({
    name: "chord_stocks",
    description: "Every tokenized stock and ETF on the chain with price, 24h change, 24h volume, trades, traders, buy share, after-hours share of the last 7 days, and the gap to the issuer's reference price (NAV) where published. Sorted by 24h volume.",
    input: z.object({ limit: z.number().int().min(1).max(200).default(50).describe("How many rows, by 24h volume") }),
    run: async ({ limit }) => {
      const d = await api<any>("/v1/rh/stocks");
      const rows = [...(d.stocks ?? [])].sort((a: any, b: any) => b.volume24h - a.volume24h).slice(0, limit).map((s: any) => ({
        symbol: s.symbol, address: s.address, priceUsd: s.priceUsd, change24hPct: s.change24hPct, volume24hUsd: Math.round(s.volume24h), trades24h: s.trades24h, traders24h: s.traders,
        buySharePct: s.volume24h > 0 ? +((s.buyVolume24h / s.volume24h) * 100).toFixed(1) : null, afterHoursSharePct7d: s.offHours7d?.sharePct == null ? null : +s.offHours7d.sharePct.toFixed(1),
        navUsd: s.navUsd, gapToNavPct: s.basisPct, liquidityUsd: s.liquidityUsd,
      }));
      return { count: d.stocks?.length ?? 0, rows, note: d.note };
    },
  }),
  tool({
    name: "chord_stock",
    description: "One tokenized stock in depth: the screener row plus activity windows (5m/1h/6h/24h buys, sells, volume, wallets), all-time high, first trade, and the pools it traded in over the last 24h.",
    input: z.object({ token: z.string().describe("Symbol like SPY or a 0x address") }),
    run: async ({ token }) => {
      const t = await resolveToken(token);
      const [st, stats] = await Promise.all([
        api<any>("/v1/rh/stocks").then((d) => (d.stocks ?? []).find((s: any) => s.address.toLowerCase() === t.address.toLowerCase()) ?? null),
        api<any>(`/v1/tokens/stats/${t.address.toLowerCase()}`).catch(() => null),
      ]);
      return { token: slim(t), screener: st, priceUsd: stats?.priceUsd ?? st?.priceUsd ?? null, windows: stats?.windows ?? null, liquidityUsd: stats?.liquidityUsd ?? null, ath: stats?.ath ?? null, range24h: stats?.range24h ?? null, firstTradeTs: stats?.firstTradeTs ?? null, totalTrades: stats?.totalTxns ?? null, pools24h: stats?.markets ?? null };
    },
  }),
  tool({
    name: "chord_quote",
    description: "Best route to swap one token for another across every venue on the chain. Amount is human units (e.g. \"0.5\" ETH). Returns the expected output, price impact, the venues on the route, and the raw quote to pass to chord_swap_tx.",
    input: z.object({
      tokenIn: z.string().describe("Symbol or address to pay with, e.g. ETH, USDG"),
      tokenOut: z.string().describe("Symbol or address to receive, e.g. NVDA"),
      amount: z.string().describe("Amount of tokenIn in human units, as a string"),
      slippageBps: z.number().int().min(1).max(5000).default(100).describe("Slippage tolerance in basis points, default 100 = 1%"),
    }),
    run: async ({ tokenIn, tokenOut, amount, slippageBps }) => {
      const [a, b] = await Promise.all([resolveToken(tokenIn), resolveToken(tokenOut)]);
      const raw = toRaw(amount, a.decimals);
      const q = await api<any>(`/v1/quote?inputMint=${a.address}&outputMint=${b.address}&amount=${raw}&slippageBps=${slippageBps}&chain=${CHAIN}`);
      const route = (q.routePlan ?? []).map((s: any) => ({ dex: s.swapInfo?.dex, percent: s.percent, in: s.swapInfo?.inputMint, out: s.swapInfo?.outputMint }));
      return {
        tokenIn: slim(a), tokenOut: slim(b), amountIn: amount,
        amountOut: q.outputAmount ? fromRaw(q.outputAmount, b.decimals) : null,
        minimumOut: q.otherAmountThreshold ? fromRaw(q.otherAmountThreshold, b.decimals) : null,
        priceImpactPct: q.priceImpactPct != null ? Number(q.priceImpactPct) : null,
        feeBps: q.feeBps ?? null, route, noRoute: (q.routePlan?.length ?? 0) === 0, noRouteReason: q.noRouteReason ?? null,
        quote: q,
      };
    },
  }),
  tool({
    name: "chord_swap_tx",
    description: "Turn a quote from chord_quote into an UNSIGNED transaction (to, data, value, gasLimit) for the given wallet. Chord never signs or holds funds: send the result to the agent's wallet to sign and broadcast on chain 4663. An ERC-20 input needs an allowance for the returned `to` first.",
    input: z.object({
      quote: z.any().describe("The `quote` object returned by chord_quote"),
      wallet: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("The wallet that will sign and receive"),
      slippageBps: z.number().int().min(1).max(5000).default(100),
    }),
    run: async ({ quote, wallet, slippageBps }) => {
      const d = await api<any>("/v1/swap", { method: "POST", body: JSON.stringify({ quoteResponse: quote, userPublicKey: wallet, slippageBps, chain: CHAIN }) });
      return { chainId: CHAIN, transaction: d.transaction, note: "Unsigned. Sign with the wallet given; the input token may need an approve() to `transaction.to` first." };
    },
  }),
  tool({
    name: "chord_smart_money",
    description: "The wallets that traded best on the chain, ranked from the tape with routers and bots removed: profit, volume, trades, win rate, best token.",
    input: z.object({ window: z.enum(["24h", "7d", "30d", "all"]).default("7d"), limit: z.number().int().min(1).max(100).default(20) }),
    run: async ({ window, limit }) => {
      const d = await api<any>(`/v1/smart-money/top?chain=${CHAIN}&window=${window}&source=onchain&limit=${limit}`);
      return { window: d.window, totalWallets: d.totalWallets, indexedToBlock: d.indexedToBlock, wallets: (d.wallets ?? []).map((w: any) => ({ wallet: w.wallet, pnlUsd: Math.round(w.pnlUsd), realizedUsd: w.realizedUsd == null ? null : Math.round(w.realizedUsd), volumeUsd: Math.round(w.volumeUsd), trades: w.trades, winRate: w.winRate, score: Math.round(w.smartScore), kind: w.archetype, topToken: w.topToken ?? null })) };
    },
  }),
  tool({
    name: "chord_wallet_pnl",
    description: "One wallet's book on the chain: realized and open profit per token from an average-cost read of its swaps, plus totals. Balances that arrived by transfer have no cost basis and are excluded.",
    input: z.object({ wallet: z.string().regex(/^0x[0-9a-fA-F]{40}$/) }),
    run: async ({ wallet }) => {
      const d = await api<any>(`/v1/portfolio/${wallet.toLowerCase()}/pnl?chain=${CHAIN}`);
      return { wallet: wallet.toLowerCase(), realizedUsd: d.realized, openUsd: d.unrealized, totalUsd: d.total, tokens: (d.tokens ?? []).map((t: any) => ({ symbol: t.symbol, token: t.token, amount: t.curAmount, valueUsd: t.curValue, avgCost: t.avgCost, realizedUsd: t.realizedUsd, openUsd: t.unrealizedUsd, roiPct: t.roiPct })) };
    },
  }),
  // ── Arc (chain 5042) — the same index on Circle's stablecoin L1 (docs/arc-tape.md). Read-only:
  // no quote / swap on Arc until Chord's router is deployed there.
  tool({
    name: "chord_arc_overview",
    description: "What the Chord index holds on Arc (chain 5042, USDC-native) right now: 24h volume in USDC, swap count, tokens traded, venues with their share, and how far back the records go. Arc is indexed by Chord itself from every Uniswap pool and launchpad on the chain.",
    input: z.object({}),
    run: async () => {
      const d = await api<any>("/v1/arc/overview");
      return { chain: d.chain, last24h: d.last24h, venues24h: (d.venues24h ?? []).map((v: any) => ({ dex: v.dex, volUsd: Math.round(v.volUsd), trades: v.trades, sharePct: +v.sharePct.toFixed(2) })), coverage: d.coverage, updatedAt: d.updatedAt };
    },
  }),
  tool({
    name: "chord_arc_tokens",
    description: "Tokens traded on Arc in the last 24h with price, 24h change, volume, buy/sell split, trades and attributed traders. Most Arc tokens are unlisted (no logo yet) but carry their on-chain symbol and name; `listed` says which have curated metadata.",
    input: z.object({ limit: z.number().int().min(1).max(200).default(50), sort: z.enum(["volume", "trades", "traders", "change"]).default("volume") }),
    run: async ({ limit, sort }) => {
      const d = await api<any>(`/v1/arc/tokens?limit=${limit}&sort=${sort}&includeUnlisted=1`);
      return { chain: d.chain, total: d.total, rows: (d.tokens ?? []).map((t: any) => ({ address: t.address, symbol: t.symbol, name: t.name, decimals: t.decimals, listed: t.listed, priceUsd: t.priceUsd, change24hPct: t.change24hPct, volume24hUsd: Math.round(t.volume24h), buySharePct: t.volume24h > 0 ? +((t.buyVolume24h / t.volume24h) * 100).toFixed(1) : null, trades24h: t.trades24h, traders: t.traders, lastTradeTs: t.lastTradeTs })) };
    },
  }),
  tool({
    name: "chord_arc_token",
    description: "One Arc token in depth: identity (on-chain symbol/name/decimals), 24h figures, an hourly volume/price series for the requested window, venue split, and every indexed pool holding it (V3/V2 pool addresses or V4 poolIds with hooks).",
    input: z.object({ address: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("Token address on Arc"), hours: z.number().int().min(1).max(720).default(168) }),
    run: async ({ address, hours }) => {
      const a = address.toLowerCase();
      const [t, p] = await Promise.all([api<any>(`/v1/arc/token/${a}?hours=${hours}`), api<any>(`/v1/arc/token/${a}/pools`).catch(() => ({ pools: [] }))]);
      return { chain: t.chain, token: t.token, hours: t.hours, series: t.series, byDex: t.byDex, pools: p.pools ?? [] };
    },
  }),
  tool({
    name: "chord_arc_venues",
    description: "Per-venue daily volume on Arc for the last N days (1..180) with each venue's share of the window — Uniswap V3, V2, V4 and the launchpad forks as separate rows.",
    input: z.object({ days: z.number().int().min(1).max(180).default(30) }),
    run: async ({ days }) => {
      const d = await api<any>(`/v1/arc/venues?days=${days}`);
      return { chain: d.chain, days: d.days, since: d.since, totals: d.totals, venues: (d.venues ?? []).map((v: any) => ({ dex: v.dex, volUsd: Math.round(v.volUsd), trades: v.trades, sharePct: +v.sharePct.toFixed(2), series: v.series })) };
    },
  }),
  tool({
    name: "chord_ask",
    description: "Ask Chord's analyst about Arc (chain 5042) in plain language and get a researched answer: trending, a token's flow/holders/risk, support and resistance with an entry ladder, top traders on a token, a wallet's PnL and trades, largest prints, launches, depth, a bridge quote, position sizing, or an ad-hoc SQL question over the index. Returns the answer text, source links, an optional route card and any tables the analysis produced. Needs a Chord API key (CHORD_API_KEY). Slower than the data tools (5–40 s); use it for judgement, use the other tools for raw numbers.",
    input: z.object({ question: z.string().min(1).max(1000), wallet: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().describe("The agent's own wallet, so 'my PnL' resolves") }),
    run: async ({ question, wallet }) => {
      if (!KEY) throw new Error("chord_ask needs CHORD_API_KEY");
      const d = await api<any>("/v1/ask", { method: "POST", body: JSON.stringify({ question, stream: false, ...(wallet ? { wallet } : {}) }) });
      return { answer: d.text, citations: d.citations, quote: d.quote, report: d.artifact?.report ?? null, tables: (d.viz ?? []).filter((v: any) => v.kind === "table"), toolsUsed: d.toolsUsed };
    },
  }),
] as const;

export type AnyTool = (typeof tools)[number];
export const toolByName = (name: string): AnyTool | undefined => tools.find((t) => t.name === name);

/** Run a tool by name with already-parsed arguments (validates against the schema). */
export async function runTool(name: string, args: unknown): Promise<unknown> {
  const t = toolByName(name); if (!t) throw new Error(`Unknown tool ${name}`);
  return t.run(t.input.parse(args ?? {}) as never);
}
