// Chord agent harness — the tools, framework-agnostic. Each tool is a name, a description an LLM can
// read, a zod input schema, and a handler that calls the Chord API and returns compact JSON. mcp.ts
// exposes them over the Model Context Protocol; manifest.ts prints them as function-calling schemas
// for OpenAI-style tool use. Everything is a read except chord_swap_tx and chord_meta_swap_tx, which return an
// UNSIGNED transaction — signing stays in the agent's own wallet, Chord never holds keys or funds.
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

// ── Meta-aggregator (GET /v1/meta/quote, POST /v1/meta/swap): every Chord chain, Chord's router first ──
const META_CHAINS = { monad: 143, robinhood: 4663, arc: 5042, avalanche: 43114, base: 8453, bnb: 56 } as const;
const META_CHAIN_KEYS = ["monad", "robinhood", "arc", "avalanche", "base", "bnb"] as const;
const NATIVE_SYMBOL: Record<number, string> = { 143: "MON", 4663: "ETH", 5042: "USDC", 43114: "AVAX", 8453: "ETH", 56: "BNB" };
const chainLists = new Map<number, { at: number; list: Token[] }>();
async function listFor(chain: number): Promise<Token[]> {
  const hit = chainLists.get(chain);
  if (hit && Date.now() - hit.at < 5 * 60_000) return hit.list;
  const d = await api<any>(`/v1/tokens?chain=${chain}`);
  const list: Token[] = Array.isArray(d) ? d : d.tokens ?? [];
  chainLists.set(chain, { at: Date.now(), list });
  return list;
}
/** A token on any Chord chain: `native` / the gas symbol / the zero address, a listed symbol, or any 0x address
 *  (decimals unknown when it is not listed — then the amount must be given raw). */
async function resolveOn(chain: number, q: string): Promise<{ address: string; symbol: string | null; decimals: number | null }> {
  const s = q.trim().toLowerCase();
  if (s === "native" || s === NATIVE || s === NATIVE_SYMBOL[chain].toLowerCase()) {
    // Arc's gas token is the USDC predeploy: the API aliases the zero address to it (6 decimals).
    return chain === 5042 ? { address: "0x3600000000000000000000000000000000000000", symbol: "USDC", decimals: 6 } : { address: NATIVE, symbol: NATIVE_SYMBOL[chain], decimals: 18 };
  }
  const list = await listFor(chain).catch(() => [] as Token[]);
  const hit = list.find((t) => t.address.toLowerCase() === s) ?? list.find((t) => t.symbol.toLowerCase() === s);
  if (hit) return { address: hit.address.toLowerCase(), symbol: hit.symbol, decimals: hit.decimals };
  if (/^0x[0-9a-f]{40}$/.test(s)) return { address: s, symbol: null, decimals: null };
  throw new Error(`No listed token on chain ${chain} matches "${q}". Pass its 0x address (with amountRaw).`);
}
type MetaArgs = { chain?: keyof typeof META_CHAINS; tokenIn?: string; tokenOut?: string; amount?: string; amountRaw?: string; slippageBps?: number; wallet?: string; quoteId?: string };
async function metaCall(method: "GET" | "POST", a: MetaArgs) {
  let chain: number, out: { decimals: number | null; symbol: string | null } | null = null, d: any;
  if (method === "POST" && a.quoteId) {
    d = await api<any>("/v1/meta/swap", { method: "POST", body: JSON.stringify({ quoteId: a.quoteId, taker: a.wallet }) });
    chain = d.chain;
  } else {
    if (!a.chain || !a.tokenIn || !a.tokenOut) throw new Error("Give chain, tokenIn and tokenOut (or a quoteId).");
    chain = META_CHAINS[a.chain];
    const [tin, tout] = await Promise.all([resolveOn(chain, a.tokenIn), resolveOn(chain, a.tokenOut)]);
    out = tout;
    let raw = a.amountRaw?.trim();
    if (!raw) {
      if (!a.amount) throw new Error("Give amount (human units) or amountRaw (smallest unit).");
      if (tin.decimals == null) throw new Error(`${a.tokenIn} is not a listed token, so its decimals are unknown here: pass amountRaw in the token's smallest unit.`);
      raw = toRaw(a.amount, tin.decimals);
    }
    const params = { chain, tokenIn: tin.address, tokenOut: tout.address, amount: raw, slippageBps: a.slippageBps ?? 50, ...(a.wallet ? { taker: a.wallet } : {}) };
    d = method === "GET"
      ? await api<any>(`/v1/meta/quote?${new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]))}`)
      : await api<any>("/v1/meta/swap", { method: "POST", body: JSON.stringify(params) });
  }
  const human = (raw: string) => (out?.decimals != null && /^\d+$/.test(raw) ? fromRaw(raw, out.decimals) : null);
  return {
    chainId: chain, provider: d.provider, fallbackReason: d.fallbackReason, noRoute: d.provider === null,
    tokenIn: d.tokenIn, tokenOut: d.tokenOut, amountInRaw: d.amountIn,
    amountOutRaw: d.amountOut, amountOut: human(d.amountOut), minAmountOutRaw: d.minAmountOut, minAmountOut: human(d.minAmountOut), tokenOutSymbol: out?.symbol ?? null,
    priceImpactPct: d.priceImpactPct != null ? Number(d.priceImpactPct) : null, valueLossPct: d.valueLossPct, feeBps: d.feeBps, feeRecipient: d.feeRecipient,
    venues: d.route?.venues ?? [], attempts: d.attempts, warnings: d.warnings, safety: d.safety,
    transaction: d.tx, approval: d.approval, simulation: d.simulation,
    quoteId: d.quoteId, expiresAt: d.expiresAt,
    note: d.provider === null ? "No provider has a route for this pair and size."
      : d.tx ? `Unsigned. ${d.provider === "chord" ? "Chord's own router" : `Chord's router did not answer (${d.fallbackReason}); this route is from ${d.provider}, a third-party aggregator`}. ${d.approval ? "Send the approval (token.approve(spender, amount)) first, then the transaction." : "No approval needed."} Sign with the wallet given, before expiresAt.`
      : "Price only. Pass `wallet` (or call chord_meta_swap_tx) for the unsigned transaction.",
  };
}

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
    name: "chord_meta_quote",
    description: "USE THIS FIRST for any swap quote. One quote on any Chord chain (monad, robinhood, arc, avalanche, base, bnb) that always ends in a route or an honest 'no route anywhere': Chord's own router answers first; a third-party aggregator (KyberSwap, Monorail, LI.FI, Relay) answers ONLY when Chord fails, and `provider` + `fallbackReason` say who answered and why. Pass `wallet` to also get the UNSIGNED transaction, the approval it needs and a simulation run as that wallet. Amount is human units (`amount`) for a listed token, or smallest units (`amountRaw`) for any address.",
    input: z.object({
      chain: z.enum(META_CHAIN_KEYS).default("robinhood").describe("Chain key"),
      tokenIn: z.string().describe("Symbol or 0x address to pay with; `native` for the chain's gas token"),
      tokenOut: z.string().describe("Symbol or 0x address to receive; `native` for the chain's gas token"),
      amount: z.string().optional().describe("Amount of tokenIn in human units, e.g. \"25\" (needs a listed token)"),
      amountRaw: z.string().optional().describe("Amount of tokenIn in its smallest unit (use this for an unlisted address)"),
      slippageBps: z.number().int().min(1).max(5000).default(50).describe("Slippage tolerance in basis points, default 50 = 0.5%"),
      wallet: z.string().optional().describe("The wallet that will sign and receive. With it the answer carries the unsigned transaction, the approval and a simulation"),
    }),
    run: async (a) => metaCall("GET", a),
  }),
  tool({
    name: "chord_meta_swap_tx",
    description: "The UNSIGNED transaction for a swap through Chord's meta-aggregator (Chord's router first, a third-party aggregator only when Chord fails). Give the `quoteId` of a chord_meta_quote answer from the last 2 minutes, or the full pair + amount. Returns `transaction` {to, data, value, gas, chainId}, the `approval` {token, spender, amount} to send first when it is not null, and `simulation` (run as the wallet: ok + the amount it receives). Chord never signs or holds funds. Fund-moving: show the person provider, amountOut, minAmountOut and the approval, and get a clear yes before signing.",
    input: z.object({
      wallet: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("The wallet that will sign and receive"),
      quoteId: z.string().optional().describe("`quoteId` from chord_meta_quote (valid 2 minutes). Without it, give chain + tokens + amount"),
      chain: z.enum(META_CHAIN_KEYS).optional(),
      tokenIn: z.string().optional(),
      tokenOut: z.string().optional(),
      amount: z.string().optional(),
      amountRaw: z.string().optional(),
      slippageBps: z.number().int().min(1).max(5000).default(50),
    }),
    run: async (a) => metaCall("POST", a),
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
  // ── LP agent (chain 5042 by default; 4663 / 143 accepted) — the pools + positions ledger (docs/lp-indexer.md).
  tool({
    name: "chord_lp_pools",
    description: "Pools ranked for a liquidity provider on Arc (or Robinhood Chain 4663 / Monad 143): TVL, volume by window, fees earned by LPs, fee/TVL and its annualised APR, 24h LP adds/removes, providers, whether a V4 hook can gate adds. Suspect pools (wash turnover, dust TVL) are flagged and hidden unless asked. Use for 'where to LP', 'best fee APR', 'is pool X worth providing to'.",
    input: z.object({ chain: z.number().int().refine((c) => c === 5042 || c === 4663 || c === 143).default(5042), sort: z.enum(["fee_tvl", "vol_24h", "vol_1h", "tvl", "fees_24h", "first_seen", "lp_net_24h", "trades_24h", "score"]).default("fee_tvl"), interval: z.enum(["1h", "6h", "24h"]).default("24h"), minTvl: z.number().min(0).optional(), quote: z.string().max(64).optional().describe("restrict to pools quoted in this token (symbol or address)"), limit: z.number().int().min(1).max(50).default(20), flagged: z.boolean().default(false).describe("include suspect pools") }),
    run: async ({ chain, sort, interval, minTvl, quote, limit, flagged }) => {
      const qs = new URLSearchParams({ chain: String(chain), sort, interval, limit: String(limit), flagged: flagged ? "1" : "0", ...(minTvl != null ? { minTvl: String(minTvl) } : {}), ...(quote ? { quote } : {}) });
      const d = await api<any>(`/v1/lp/pools?${qs}`);
      return { chain: d.chain, total: d.total, hidden: d.hidden, sort: d.sort, rows: (d.pools ?? []).map((p: any) => ({ pool: p.pool, pair: `${p.token0?.symbol ?? p.token0?.address?.slice(0, 8)}/${p.token1?.symbol ?? p.token1?.address?.slice(0, 8)}`, dex: p.dex, kind: p.kind, feeBps: p.feeBps, lpAccess: p.lpAccess, tvlUsd: p.tvlUsd == null ? null : Math.round(p.tvlUsd), vol24hUsd: Math.round(p.vol?.h24 ?? 0), fees24hUsd: p.fees?.h24 == null ? null : Math.round(p.fees.h24), feeTvlPct24h: p.feeTvlPct?.h24 ?? null, aprPct: p.aprPct ?? null, score: p.score ?? null, lpAdd24hUsd: Math.round(p.lpAdd24h ?? 0), lpRemove24hUsd: Math.round(p.lpRemove24h ?? 0), providers24h: p.providers24h ?? null, trades24h: p.trades24h, wallets24h: p.wallets24h, turnover24h: p.turnover24h, suspect: !!p.suspect })) };
    },
  }),
  tool({
    name: "chord_lp_positions",
    description: "A wallet's liquidity positions (Uniswap V3/V4 position NFTs) from Chord's LP ledger: pool, venue, fee tier, range, in range now and distance to the edge, dollars in/out, value now, fees earned and uncollected, PnL, age, JIT flag; plus a summary (open/closed, win rate, realized PnL, fees).",
    input: z.object({ wallet: z.string().regex(/^0x[0-9a-fA-F]{40}$/), chain: z.number().int().refine((c) => c === 5042 || c === 4663 || c === 143).default(5042), status: z.enum(["open", "closed", "all"]).default("open"), limit: z.number().int().min(1).max(100).default(50) }),
    run: async ({ wallet, chain, status, limit }) => {
      const d = await api<any>(`/v1/lp/positions?chain=${chain}&owner=${wallet.toLowerCase()}&status=${status}&limit=${limit}`);
      return { chain: d.chain, owner: d.owner, summary: d.summary, positions: (d.positions ?? []).map((p: any) => ({ manager: p.manager, tokenId: p.tokenId, pool: p.pool, pair: `${p.symbol ?? "?"}/${p.anchorSymbol ?? "?"}`, dex: p.dex, kind: p.kind, status: p.status, inRange: p.inRange, edgePct: p.edgePct, inUsd: Math.round(p.inUsd), outUsd: Math.round(p.outUsd), valueUsd: p.valueUsd == null ? null : Math.round(p.valueUsd), feesUsd: Math.round(p.feesUsd), uncollectedUsd: p.uncollectedUsd == null ? null : Math.round(p.uncollectedUsd), pnlUsd: p.pnlUsd == null ? null : Math.round(p.pnlUsd), pnlPct: p.pnlPct, ageHours: p.ageHours == null ? null : Math.round(p.ageHours), openedTs: p.openedTs, closedTs: p.closedTs, jit: p.jit, unreconciled: p.unreconciled })) };
    },
  }),
  tool({
    name: "chord_lp_leaderboard",
    description: "Top liquidity providers from the position ledger (LP Agent style): profit 7d/30d/all, win rate, fees, positions, pools, average age and invested size, what they provide to. JIT and same-operator clusters are excluded; filters mirror LP Agent's panel.",
    input: z.object({ chain: z.number().int().refine((c) => c === 5042 || c === 4663 || c === 143).default(5042), sort: z.enum(["profit", "win_rate", "avg_age", "positions", "pools", "ev", "avg_invested", "monthly_profit", "fees", "last_activity"]).default("profit"), limit: z.number().int().min(1).max(100).default(25), minPositions: z.number().int().min(0).optional(), minAgeHours: z.number().min(0).optional(), minWinRate: z.number().min(0).max(100).optional() }),
    run: async ({ chain, sort, limit, minPositions, minAgeHours, minWinRate }) => {
      const qs = new URLSearchParams({ chain: String(chain), sort, limit: String(limit), ...(minPositions != null ? { minPositions: String(minPositions) } : {}), ...(minAgeHours != null ? { minAgeHours: String(minAgeHours) } : {}), ...(minWinRate != null ? { minWinRate: String(minWinRate) } : {}) });
      const d = await api<any>(`/v1/lp/leaderboard?${qs}`);
      return { chain: d.chain, sort: d.sort, rows: (d.rows ?? []).map((r: any) => ({ wallet: r.wallet, profit7dUsd: Math.round(r.windows?.d7?.profitUsd ?? 0), profit30dUsd: Math.round(r.windows?.d30?.profitUsd ?? 0), profitAllUsd: Math.round(r.windows?.all?.profitUsd ?? 0), winRatePct: r.winRatePct, feesUsd: Math.round(r.feesUsd ?? 0), positions: r.windows?.all?.positions ?? null, open: r.open, pools: r.pools, avgAgeHours: r.avgAgeHours, avgInvestedUsd: r.avgInvestedUsd, tokens: (r.tokens ?? []).slice(0, 5).map((t: any) => t.symbol ?? t.address), lastTs: r.lastTs })) };
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
