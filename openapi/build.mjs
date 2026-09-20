// Builds openapi/chord.json (OpenAPI 3.1) — the Chord API contract that starlight-openapi turns into
// the "API reference" section, and that is served verbatim at /docs/openapi.json for codegen and
// LLM tool-use. Hand-maintained, like packages/api/src/routes/openapi.ts (the NullTerminal spec):
// the route surface changes rarely and rewiring every Hono route through zod-openapi is not worth
// the risk. Examples come from openapi/examples.json — real responses captured from
// api.getchord.xyz (arrays trimmed to two rows), so a reader sees the true shape, not a sketch.
//
// Scope = the Chord surface: everything the Chord app calls on chains 5042 (Arc) and 4663
// (Robinhood Chain), plus the developer/agent endpoints. Monad-only routes and the admin/app
// consoles are left out on purpose.
//
// Keep in sync with packages/api/src/routes/*.ts. When a route changes, change the schema here in the
// same commit (CLAUDE.md "cross-package seams"). `pnpm --filter @nullterminal/docs-chord build` fails
// on an unparsable document; it does not check the shapes against the code — you do.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const EX = JSON.parse(readFileSync(join(here, "examples.json"), "utf8"));
const ex = (key) => {
  const v = EX[key];
  if (v === undefined) throw new Error(`examples.json has no entry for ${key}`);
  return v;
};

// Sample identities used by the captured examples (openapi/examples.json).
const TOK = "0x171a4217b86a807a64eb94757db6849fb4bdbaa0"; // cirBTC on Arc
const WAL = "0xb145400da27a2497d9fc2cd5621f2bfd37617af4";
const POOL = "0xf53f02d9041d00bbd92235b4c902b9f350c554a8ed2dc64fa0a4585aac413f09"; // USDC/MURMUR V4
const USDC = "0x3600000000000000000000000000000000000000";
const ROUTER = "0x1b1fee89a381e595fe6536b99ba91f3e16e9601a";

// ── schema helpers ────────────────────────────────────────────────────────────────────────────
const str = (description, extra = {}) => ({ type: "string", description, ...extra });
const num = (description, extra = {}) => ({ type: "number", description, ...extra });
const int = (description, extra = {}) => ({ type: "integer", description, ...extra });
const bool = (description) => ({ type: "boolean", description });
const nullable = (schema) => ({ ...schema, type: [schema.type, "null"] });
const arr = (items, description) => ({ type: "array", items, ...(description ? { description } : {}) });
const obj = (properties, description, extra = {}) => ({ type: "object", properties, ...(description ? { description } : {}), ...extra });
const ref = (name) => ({ $ref: `#/components/schemas/${name}` });
const loose = (description) => ({ type: "object", additionalProperties: true, description });

const ADDRESS = { type: "string", pattern: "^0x[a-fA-F0-9]{40}$", description: "EVM address, hex, case-insensitive." };
const POOL_ID = { type: "string", pattern: "^0x([a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", description: "A pool: a 20-byte contract address (V2 / V3) or a 32-byte Uniswap V4 pool id." };
const WEI = { type: "string", pattern: "^\\d+$", description: "Amount in the token's smallest unit, as a decimal string. Never a float." };
const TX_HASH = { type: "string", pattern: "^0x[a-fA-F0-9]{64}$", description: "Transaction hash." };
const UNIX_S = int("Unix time, seconds, UTC.");
const UNIX_MS = int("Unix time, milliseconds — when the server built this answer.");

const q = (name, schema, description, required = false) => ({ name, in: "query", required, schema, description });
const p = (name, schema, description) => ({ name, in: "path", required: true, schema, description });
const CHAIN_DESC = { 5042: "Arc", 4663: "Robinhood Chain", 143: "Monad" };
const chainQ = (chains, { required = false, def, note = "" } = {}) => {
  const list = chains.map((c) => `\`${c}\` ${CHAIN_DESC[c]}`).join(" · ");
  return q("chain", { type: "integer", enum: chains, ...(def !== undefined ? { default: def } : {}) }, `Chain id: ${list}.${def !== undefined ? ` Omitted = ${def}.` : ""}${note ? ` ${note}` : ""}`, required);
};

const json = (schema, example) => ({ "application/json": { schema, ...(example !== undefined ? { example } : {}) } });
const ok = (description, schema, example) => ({ description, content: json(schema, example) });
const errRes = (description) => ({ description, content: json(ref("Error")) });
const ERR = {
  400: errRes("Invalid parameters — `error` names the check that failed (`INVALID_PARAMS`, `BAD_ADDRESS`, `BAD_LIMIT`, `BAD_HOURS`, …)."),
  401: errRes("Missing or unknown credential (`UNAUTHORIZED`)."),
  404: errRes("Nothing at this identity (`NOT_FOUND`, `UNKNOWN_TOKEN`, `NO_ROUTE`)."),
  429: errRes("Over the per-minute limit (`RATE_LIMIT_EXCEEDED`). Read `X-RateLimit-Reset` and back off."),
  502: errRes("The routing engine or an upstream did not answer (`ENGINE_ERROR`, `ROUTE_ERROR`)."),
  503: errRes("The lane behind this endpoint is not ready or not enabled here (`NOT_READY`, `CHAIN_NOT_ENABLED`, `NOT_ENABLED`, `*_UNAVAILABLE`). Retry later; do not treat it as an empty answer."),
};
const withErr = (responses, codes) => { for (const c of codes) responses[String(c)] = ERR[c]; return responses; };

const op = (tag, operationId, summary, description, { params = [], body, responses, security } = {}) => ({
  tags: [tag],
  operationId,
  summary,
  description,
  ...(params.length ? { parameters: params } : {}),
  ...(body ? { requestBody: body } : {}),
  responses,
  ...(security ? { security } : {}),
});
const bodyJson = (schema, example, description) => ({ required: true, description, content: json(schema, example) });

// ── components ────────────────────────────────────────────────────────────────────────────────
const TokenLite = obj({
  address: ADDRESS, symbol: nullable(str("Symbol from the contract, or null while unresolved.")), decimals: nullable(int("ERC-20 decimals.")),
  logo: nullable(str("Logo URL, or null.")), impostor: bool("True when the symbol copies the chain's anchor (a token called USDC that is not the USDC predeploy). Flagged, never hidden."),
}, "A token as it appears inside a pool row.");

const Coverage = obj({
  recentAt: nullable(UNIX_S), stale: bool("True when the most recent rolled-up hour is older than the lane's freshness bar."),
  floorHour: nullable(int("Oldest hour the rollup has reached so far.")), genesisHour: nullable(int("The chain's first indexed hour.")),
  backfillComplete: bool("True once the rollup reaches genesis — before that, long windows undercount."),
}, "How fresh and how deep the rolled-up data is. Trust these flags, not the clock.");

const ArcTokenRow = obj({
  address: ADDRESS, symbol: nullable(str("")), name: nullable(str("")), decimals: nullable(int("")), logoURI: nullable(str("Logo through Chord's proxy (`/v1/logo/5042/{address}`, 128 px WebP).")),
  logoUriRaw: nullable(str("The upstream logo URL the proxy fetched, when there is one.")),
  tags: arr({ type: "string" }, "`stablecoin`, `fx`, `stock`, … — from the curated list; empty for unlisted tokens."),
  listed: bool("On the curated Arc token list (metadata and logo vetted)."),
  priceUsd: nullable(num("Last trade price on the token's dominant venue, USD.")), change24hPct: nullable(num("")),
  volume24h: num("USD, every venue, no dust floor."), buyVolume24h: num(""), sellVolume24h: num(""),
  trades24h: int(""), buys24h: int(""), sells24h: int(""),
  traders: int("Distinct attributed wallets over the board's day window. Routers, executors and bots are not wallets."),
  lastTradeTs: UNIX_S,
  totalSupply: nullable(num("`totalSupply()` in whole tokens. Null when unreadable.")),
  marketCapUsd: nullable(num("totalSupply × price — fully diluted, since nothing on-chain says what is locked.")),
  pools: obj({ v3: int(""), v2: int(""), v4: int(""), byDex: obj({}, "Pool count per venue id (`uniswap_v3`, `uniswap_v4`, `pools_trade`, `slipstream_fork`, `v3fork_<8hex>`, …).", { additionalProperties: { type: "integer" } }) }, "Indexed pools holding the token."),
  routable: bool("The engine can quote this token today (at least one pool against a routing anchor)."),
  flags: arr({ type: "string", enum: ["wash", "impostor"] }, "Honesty flags. `wash` = a day's volume carried by one or two wallets; `impostor` = an unlisted token wearing a listed symbol. Absent when clean."),
}, "One token on Arc with its 24-hour tape.");

const ArcTrendingRow = { allOf: [ref("ArcTokenRow"), obj({ score: num("Trending score (higher = hotter)."), volNow: num("USD in the 2-hour window."), tradesNow: int(""), change1hPct: nullable(num("")), momentum: nullable(num("")) })] };
const ArcGraduatedRow = { allOf: [ref("ArcTokenRow"), obj({ launchedAt: UNIX_S, launcher: str("Contract the creating transaction called (`create` = a raw deploy)."), launcherName: nullable(str("Name from the launcher registry, when known.")), creator: ADDRESS, ageSec: int("") })] };

const RhTokenRow = obj({
  address: ADDRESS, symbol: str(""), name: str(""), decimals: int(""), logoURI: nullable(str("")), tags: arr({ type: "string" }, "`stock`, `bridged`, `stablecoin`, …"), listed: bool(""),
  priceUsd: nullable(num("")), change24hPct: nullable(num("")), liquidityUsd: nullable(num("")),
  volume24h: num(""), buyVolume24h: num(""), sellVolume24h: num(""), trades24h: int(""), buys24h: int(""), sells24h: int(""), traders: int("Attributed wallets only."), lastTradeTs: UNIX_S,
}, "One token on Robinhood Chain with its 24-hour tape.");
const RhStockRow = { allOf: [ref("RhTokenRow"), obj({
  navUsd: nullable(num("The issuer's published exchange rate at last refresh; null when none is published.")),
  basisPct: nullable(num("On-chain price versus NAV, percent.")),
  offHours7d: obj({ volUsd: num(""), trades: int(""), sharePct: num("") }, "Activity outside the NYSE regular session (09:30–16:00 New York, weekdays) over the last seven days."),
})] };

const RouteLeg = obj({
  percent: int("Share of the input this leg carries."),
  swapInfo: obj({
    dex: str("Venue id (see Resources → Venue ids)."), pool: str("Pool address, or the 32-byte pool id on Uniswap V4."),
    inputMint: ADDRESS, outputMint: ADDRESS, inputAmount: WEI, outputAmount: WEI,
    adapter: str("The router adapter that executes this leg — from the engine, never hardcode."), extraData: str("Adapter-specific calldata for the leg."),
    feeAmount: WEI, feeMint: ADDRESS,
  }),
}, "One leg of the route.");

const QuoteResponse = obj({
  inputMint: ADDRESS, outputMint: ADDRESS, inputAmount: WEI,
  outputAmount: WEI, otherAmountThreshold: { ...WEI, description: "Minimum output after fee and slippage — the number the transaction enforces." },
  slippageBps: int(""), priceImpactPct: str("Percent, as a string, against the spot rate of the same route."),
  routePlan: arr(ref("RouteLeg"), "Empty with `outputAmount` \"0\" = no route (an honest answer, never a fabricated price)."),
  noRouteReason: str("Only when `routePlan` is empty: `INSUFFICIENT_LIQUIDITY` (try a smaller amount) or `NO_POOLS`."),
  gasEstimate: str("Gas units, from the venue quoter or the RPC."), gasCostUSD: str(""), blockNumber: int(""), timeTaken: num("Engine seconds."),
  feeBps: int("Protocol fee on the output token — tiered per token on-chain (`FeeCollector.feeBpsFor`): 0 on USDC/EURC on Arc, 25 default for new tokens."),
  feeAmount: WEI, feeMint: ADDRESS, feeTier: str("`major` · `stable` · `standard` · `meme` · `new`."),
  preliminary: bool("Present only on `fast=1` answers: single-hop, ~400 ms, replace it with the full quote."),
});

const SwapTx = obj({ to: ADDRESS, data: str("Calldata."), value: WEI, gasLimit: str(""), chainId: int("") }, "Unsigned transaction against the router.");

const Candle = obj({ t: UNIX_S, o: num(""), h: num(""), l: num(""), c: num(""), v: num("USD volume in the bucket.") });
const TradeRow = obj({ tx: TX_HASH, logIndex: int(""), dex: str(""), side: { type: "string", enum: ["buy", "sell"] }, tokenAmt: num(""), usd: num(""), priceUsd: num(""), ts: UNIX_S, wallet: nullable(ADDRESS) });
const StatsWindow = obj({ change: num("Percent."), txns: int(""), buys: int(""), sells: int(""), buyVol: num(""), sellVol: num(""), makers: int(""), buyers: int(""), sellers: int("") });

const SmartWallet = obj({
  wallet: ADDRESS, pnlUsd: num("Realized plus open PnL at current prices."), realizedUsd: num(""), unrealizedUsd: num(""), volumeUsd: num(""), trades: int(""), tokensTraded: int(""), winningTokens: int(""), winRate: num("0–1."),
  topToken: obj({ symbol: nullable(str("")), pnlUsd: num("") }), lastActiveTs: UNIX_S, pnlMeme: num(""), pnlMajor: num(""), memeVol: num(""), archetype: str("`degen` · `allrounder` · `majors` …"), memeShare: num(""), winRateAdj: num("Luck-corrected win rate."),
  smartScore: num("The ranking key: realized-weighted, luck-corrected, recency-decayed profit."),
});

const PnlToken = obj({
  token: ADDRESS, symbol: nullable(str("")), logo: nullable(str("")), realizedUsd: num(""), unrealizedUsd: num(""), totalUsd: num(""), costRemaining: num(""), curValue: num(""), curAmount: num(""), avgCost: num("Average cost per token, USD."), roiPct: nullable(num("")),
  untrackedAmount: num("Balance that arrived by transfer (no cost basis)."), untrackedValue: num(""),
});

const LpEvent = obj({
  tx: TX_HASH, logIndex: int(""), pool: POOL_ID, dex: str(""), kind: { type: "string", enum: ["add", "remove", "collect"] }, wallet: nullable(ADDRESS), token: ADDRESS, tokenAmt: num(""), anchor: ADDRESS, anchorAmt: num(""),
  usd: num("Dollars that entered or left the pool."), priced: bool("False when the event could not be valued (no anchor side)."), tickLower: nullable(int("")), tickUpper: nullable(int("")), block: int(""), ts: UNIX_S, manager: nullable(ADDRESS), tokenId: nullable(str("Position NFT id, for managed positions.")),
});

const PoolListRow = obj({
  pool: POOL_ID, dex: str(""), kind: { type: "string", enum: ["v2", "clmm", "v4"] }, feeBps: nullable(num("")), hooks: nullable(ADDRESS), lpAccess: { type: "string", enum: ["open", "hooked", "unknown"], description: "`hooked` = a V4 hook can refuse adds." }, tickSpacing: nullable(int("")),
  token0: ref("TokenLite"), token1: ref("TokenLite"), tokenSide: nullable(int("Which side is the non-anchor token (0 or 1).")),
  tvlUsd: nullable(num("")), tvlSrc: nullable(str("Where TVL came from (`onchain`, `dexscreener`, …).")), tvlAt: nullable(UNIX_S),
  vol: obj({ h1: num(""), h6: num(""), h24: num(""), d7: num("") }), fees: obj({ h1: nullable(num("")), h6: nullable(num("")), h24: nullable(num("")) }, "volume × the pool's fee tier."),
  feeTvlPct: obj({ h1: nullable(num("")), h6: nullable(num("")), h24: nullable(num("")) }, "fees ÷ TVL, percent."), aprPct: nullable(num("24h fee/TVL × 365 — a full-range yardstick, not a promise.")),
  trades24h: int(""), wallets24h: int(""), priceUsd: nullable(num("")), lpAdd24h: num(""), lpRemove24h: num(""), providers24h: int(""), firstSeenTs: UNIX_S, createdTs: nullable(UNIX_S), lastTradeHour: int(""),
  turnover24h: nullable(num("24h volume ÷ TVL.")), suspect: bool("Wash or launch-farm printing (volume without traders, dust TVL under real volume, turnover no honest pool reaches). Hidden by default; `flagged=1` shows them."),
  score: int("0–100 health score (traders, TVL, yield sanity, LP flow, age, penalties)."),
});

const LpPosition = obj({
  manager: ADDRESS, tokenId: str(""), pool: nullable(POOL_ID), dex: nullable(str("")), kind: { type: "string", enum: ["v3", "v4"] }, owner: nullable(ADDRESS), token: nullable(ADDRESS), anchor: nullable(ADDRESS), tickLower: nullable(int("")), tickUpper: nullable(int("")),
  symbol: nullable(str("")), anchorSymbol: nullable(str("")), logo: nullable(str("")),
  inUsd: num("Dollars added."), outUsd: num("Dollars removed."), feesUsd: num("Fees collected."), adds: int(""), removes: int(""), collects: int(""), openedTs: nullable(UNIX_S), lastTs: UNIX_S, closedTs: nullable(UNIX_S), burned: bool(""), status: { type: "string", enum: ["open", "closed"] },
  valueUsd: nullable(num("Live value of the liquidity (open positions).")), uncollectedUsd: nullable(num("Uncollected fees (V3).")), inRange: nullable(bool("")), pnlUsd: nullable(num("Liquidity leg only.")), pnlPct: nullable(num("")), ageHours: nullable(num("")), edgePct: nullable(num("Distance from the price to the nearest range edge, percent.")),
  jit: bool("Opened and closed within seconds — a swap trick, shown but not scored."), unreconciled: bool("Dollars out exceed dollars in by far — the tape missed an add; shown, never scored."),
});

const LpLeaderRow = obj({
  wallet: ADDRESS, winRatePct: nullable(num("")), feesUsd: num(""), pools: int(""), evUsd: nullable(num("Expected value per position.")), avgAgeHours: nullable(num("")), avgInvestedUsd: nullable(num("")), avgMonthlyProfitUsd: nullable(num("")),
  windows: obj({ d7: obj({ positions: int(""), profitUsd: num("") }), d30: obj({ positions: int(""), profitUsd: num("") }), all: obj({ positions: int(""), profitUsd: num("") }) }),
  open: int(""), closed: int(""), wins: int(""), firstTs: nullable(UNIX_S), lastTs: UNIX_S, daily: arr(obj({ day: str("YYYY-MM-DD"), profitUsd: num("") }), "Last 7 days."),
  tokens: arr(obj({ address: ADDRESS, symbol: nullable(str("")), logo: nullable(str("")), inUsd: num(""), positions: int("") }), "What the wallet provides to, by dollars in."),
});

const SimResult = obj({
  pool: POOL_ID, dex: str(""), feeBps: nullable(num("")), tvlUsd: nullable(num("")), days: int(""), hours: int("Candles replayed."), hoursInRange: int(""), inRangePct: num(""), exits: int("Times the price left the range."),
  lower: num(""), upper: num(""), unreliable: nullable(str("Why the number should not be trusted, when it should not.")), entryPrice: num(""), exitPrice: num(""), priceChangePct: num(""),
  feesUsd: num(""), lpValueEndUsd: num(""), holdValueEndUsd: num(""), ilUsd: num("Impermanent loss (negative = loss)."), netVsHoldUsd: num(""), totalReturnUsd: num(""), totalReturnPct: num(""), feeAprPct: num(""), capitalEfficiency: num("Versus full range."), shareOfPoolPct: num(""), note: str(""),
}, "One range, backtested on Chord's own candles and the pool's real fee tier.");

const LauncherStat = obj({
  launcher: ADDRESS, name: nullable(str("")), site: nullable(str("")), logo: nullable(str("")), kinds: arr({ type: "string", enum: ["v2", "v3", "v4"] }),
  shapes: arr(obj({ hooks: nullable(ADDRESS), fee: nullable(int("")), tickSpacing: nullable(int("")), pools: int("") }), "The pool templates this launcher creates."),
  pools1h: int(""), pools24h: int(""), creators24h: int("Distinct creator wallets."), firstSeen: UNIX_S, lastSeen: UNIX_S,
  swaps24h: nullable(int("")), volume24h: nullable(num("")), wallets24h: nullable(int("")), activePools24h: nullable(int("")),
});

const components = {
  securitySchemes: {
    ApiKey: { type: "apiKey", in: "header", name: "X-API-Key", description: "Optional on every read. A key from getchord.xyz/developer raises the rate limit to your plan and meters usage per key. Required for `?only=` on quotes and for the Ask agent API." },
    Session: { type: "http", scheme: "bearer", description: "A Google sign-in session minted by the app (`nts_…`). Only the browser surfaces use it; agents use `ApiKey`." },
  },
  schemas: {
    Error: obj({ error: str("Stable machine code, e.g. `INVALID_PARAMS`, `NOT_READY`, `RATE_LIMIT_EXCEEDED`."), message: str("For humans."), statusCode: int("HTTP status, when included.") }, "Every non-2xx body.", { required: ["error"], example: { error: "INVALID_PARAMS", message: "amount must be an integer string in the token's smallest unit" } }),
    Coverage, TokenLite, ArcTokenRow, ArcTrendingRow, ArcGraduatedRow, RhTokenRow, RhStockRow, RouteLeg, QuoteResponse, SwapTx, Candle, TradeRow, StatsWindow, SmartWallet, PnlToken, LpEvent, PoolListRow, LpPosition, LpLeaderRow, SimResult, LauncherStat,
  },
};

// ── paths ─────────────────────────────────────────────────────────────────────────────────────
const paths = {};
const add = (path, method, operation) => { (paths[path] ??= {})[method] = operation; };

const T = {
  swap: "Quote and swap",
  arc: "Arc data",
  tokens: "Tokens and charts",
  wallets: "Top wallets",
  portfolio: "Portfolio",
  lp: "Liquidity",
  points: "Points",
  ask: "Ask agent",
  bridge: "Bridge",
  rh: "Robinhood Chain data",
  stream: "Streaming",
  account: "Account and health",
};

// Quote and swap ───────────────────────────────────────────────────────────────────────────────
add("/quote", "get", op(T.swap, "getQuote", "Best route for a swap",
`Quotes every venue on the chain in parallel, splits the order across venues when that improves the output, composes a two-hop route through the chain's anchors when no direct pool wins, and returns the best.

**Use it for**: a price before a trade, a route card, an agent deciding whether to buy, a bot comparing venues.

**Notes**
- Amounts are strings in the token's smallest unit. On Arc the USDC predeploy has 6 decimals, native USDC 18 — send the predeploy address \`0x3600…0000\` (the zero address is an alias for it on 5042).
- A quote is a live read of the venues and is good for about 30 seconds. Re-quote before you build if you waited longer.
- \`fast=1\` returns a single-hop answer in about 400 ms marked \`preliminary\`; run the full quote alongside and replace it.
- \`only=\` pins one venue and bypasses the routing safety gates — it needs an API key.
- An empty \`routePlan\` is a real answer (no route at this size); read \`noRouteReason\`.`,
  {
    params: [
      chainQ([5042, 4663, 143], { def: 143, note: "Chord surfaces are 5042 and 4663. Always pass it." }),
      q("inputMint", ADDRESS, "Token you sell. The zero address means the native unit (an alias for the USDC predeploy on Arc; ETH on Robinhood Chain).", true),
      q("outputMint", ADDRESS, "Token you buy.", true),
      q("amount", WEI, "Input amount, smallest unit.", true),
      q("slippageBps", { type: "integer", minimum: 1, maximum: 5000, default: 50 }, "Slippage tolerance in basis points; sets `otherAmountThreshold`."),
      q("fast", { type: "integer", enum: [0, 1] }, "1 = progressive first frame (single-hop, ~400 ms, `preliminary: true`)."),
      q("only", { type: "string", pattern: "^[a-z0-9_]+$" }, "Debug: restrict routing to one venue id. Requires `X-API-Key`."),
    ],
    responses: withErr({ 200: ok("The best route. `routePlan` empty + `outputAmount` \"0\" = no route.", ref("QuoteResponse"), ex(`/v1/quote?chain=5042&inputMint=${USDC}&outputMint=${TOK}&amount=5000000&slippageBps=100`)) }, [400, 429, 502, 503]),
  }));

add("/swap", "post", op(T.swap, "buildSwap", "Build an unsigned swap transaction",
`Turns a quote into a transaction against the Chord router. You sign it and broadcast it; Chord never sees a key and never holds funds.

**Notes**
- Send the \`/quote\` body back unmodified. \`chain\` must match the quote.
- For an ERC-20 input, approve the router (\`transaction.to\`) for at least \`inputAmount\` first — or run \`/swap/simulate\` and let it tell you.
- \`slippageBps\` is a consistency check only: the signed minimum output is the quote's \`otherAmountThreshold\`. A different value is refused with \`SLIPPAGE_MISMATCH\` — re-quote at the slippage you want.
- On Arc the native sentinel aliases to the USDC predeploy: a "native" input is pulled by \`transferFrom\`, a "native" output is delivered as the predeploy, and \`value\` is always 0.
- \`batch: "7702"\` is Monad-only (EIP-7702 one-signature approve+swap); it is ignored on 5042 / 4663.`,
  {
    body: bodyJson(obj({
      quoteResponse: ref("QuoteResponse"), userPublicKey: { ...ADDRESS, description: "Wallet that signs and receives the output." },
      chain: { type: "integer", enum: [5042, 4663, 143], default: 143, description: "Must match the quote." },
      slippageBps: { type: "integer", minimum: 1, maximum: 5000, description: "Optional consistency check — same value the quote was requested with." },
      feeAccount: { ...ADDRESS, description: "Referrer credited with the referral share of the protocol fee." },
      wrapUnwrapMON: { type: "boolean", default: true, description: "Wrap / unwrap the native unit around the swap where the chain has a wrapped native (not Arc)." },
      usePermit2: { type: "boolean", default: false }, batch: { type: "string", enum: ["7702"] },
    }, undefined, { required: ["quoteResponse", "userPublicKey"] }), { quoteResponse: { "…": "the /v1/quote body" }, userPublicKey: WAL, chain: 5042 }),
    responses: withErr({ 200: ok("Sign `transaction` with any wallet library and submit it to the chain in `chainId`.", obj({ transaction: ref("SwapTx"), lastValidBlockHeight: int("Block after which the quote should be considered stale."), batch7702: loose("Monad only — the one-signature approve+swap plan.") }), { transaction: { to: ROUTER, data: "0xdc72a437…", value: "0", gasLimit: "1500000", chainId: 5042 }, lastValidBlockHeight: 21808340 }) }, [400, 429, 502]),
  }));

add("/swap/calldata", "get", op(T.swap, "swapCalldata", "Quote and build in one call",
`For contracts and bots that call the router directly: routes and encodes in a single request. The output goes to \`msg.sender\`; the caller approves the router for \`tokenIn\` and sends the calldata.`,
  {
    params: [chainQ([5042, 4663, 143], { def: 143 }), q("tokenIn", ADDRESS, "Token the caller approves and sends.", true), q("tokenOut", ADDRESS, "Token returned to msg.sender.", true), q("amountIn", WEI, "", true), q("slippageBps", { type: "integer", minimum: 1, maximum: 5000, default: 100 }, "Sets `minOut` on the returned calldata.")],
    responses: withErr({ 200: ok("Router call.", obj({ to: ADDRESS, data: str(""), value: WEI, minOut: str("Minimum output, human units."), expectedOut: str("Quoted output, human units."), gasLimit: str("") }), { to: ROUTER, data: "0x…", value: "0", minOut: "0.0942", expectedOut: "0.0951", gasLimit: "1000000" }) }, [400, 404, 429, 502]),
  }));

add("/swap/simulate", "post", op(T.swap, "simulateSwap", "Simulate a built transaction before signing",
`\`eth_call\`s the built calldata from the user's address and estimates gas, so a revert is caught before the wallet opens. Known selectors are decoded (\`NotRouter\`, a paused Kuru market, allowance and balance errors). An allowance revert is advisory: approve first, then swap.`,
  {
    body: bodyJson(obj({ chain: { type: "integer", enum: [5042, 4663, 143] }, from: ADDRESS, to: ADDRESS, data: str("Calldata from `/swap`."), value: WEI }, undefined, { required: ["from", "to", "data", "value"] }), { chain: 5042, from: WAL, to: ROUTER, data: "0xdc72a437…", value: "0" }),
    responses: withErr({ 200: ok("`ok: true` with the simulated output and gas, or `ok: false` with the decoded revert.", obj({ ok: bool(""), amountOut: nullable(str("Simulated output, smallest unit.")), gas: nullable(int("Estimated gas units.")), revert: str("Decoded reason (when `ok` is false)."), selector: nullable(str("4-byte error selector.")) }), { ok: true, amountOut: "465", gas: 318189 }) }, [400, 503]),
  }));

// Arc data ─────────────────────────────────────────────────────────────────────────────────────
const ARC_INTRO = "Served from Chord's rollup and index tables (every swap on Arc summed by hour, token and venue), never from a raw scan — so calls are cheap and every answer carries its coverage. No key needed. `503 NOT_READY` until the rollup has run on the deployment.";

add("/arc/status", "get", op(T.arc, "arcStatus", "Index freshness and depth", `Is the Arc rollup fresh, how far back it reaches, and the state of the pool index and the holder ledger. Check this before trusting a quiet number.\n\n${ARC_INTRO}`,
  { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, enabled: bool(""), recentAt: nullable(UNIX_S), staleSec: nullable(int("")), floorHour: nullable(int("")), genesisHour: nullable(int("")), backfillComplete: bool(""), index: nullable(obj({ pools: int("V2 + V3 pools indexed."), v4Pools: int(""), cursor: int("Last block the pool crawler processed."), genesis: bool("Pool discovery reached genesis.") })), holders: nullable(loose("Holder-ledger lane state (tracked tokens, completed backfills, cursors).")), updatedAt: UNIX_MS }), ex("/v1/arc/status")) }, [503]) }));

add("/arc/overview", "get", op(T.arc, "arcOverview", "Chain totals", `Last 24 hours (volume, swaps, tokens), venue share, 24 hourly buckets and up to 30 daily rows. The numbers on Chord's landing page come from this call.\n\n${ARC_INTRO}`,
  { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, last24h: obj({ volUsd: num(""), swaps: int(""), tokens: int(""), sinceHour: int("") }), venues24h: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), tokens: int(""), sharePct: num("") }), "Biggest first."), hourly24: arr(obj({ hour: int(""), volUsd: num(""), swaps: int("") }), "Oldest first."), daily: arr(obj({ day: int(""), swaps: int(""), volUsd: num(""), tokens: int(""), wallets: int("Attributed wallets only."), venues: int("") }), "Up to 30 days."), coverage: ref("Coverage"), updatedAt: UNIX_MS }), ex("/v1/arc/overview")) }, [503]) }));

add("/arc/venues", "get", op(T.arc, "arcVenues", "Venue share over a window", `Per-venue volume, trades and share for 1–180 days, with a daily series per venue. Venue ids are listed under Resources → Venue ids.\n\n${ARC_INTRO}`,
  { params: [q("days", { type: "integer", minimum: 1, maximum: 180, default: 30 }, "Window length.")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, days: int(""), since: UNIX_S, venues: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num(""), series: arr(obj({ day: int(""), volUsd: num(""), trades: int(""), tokens: int("") })) })), totals: obj({ volUsd: num(""), trades: int("") }), updatedAt: UNIX_MS }), ex("/v1/arc/venues?days=2")) }, [400, 503]) }));

add("/arc/tokens", "get", op(T.arc, "arcTokens", "Every token traded in the last 24 hours", `The Markets board: price, change, volume split, trade counts, attributed traders, market cap, pool counts per venue and honesty flags for every token that traded on Arc in the last 24 hours — listed or not. Rows flagged \`wash\` or \`impostor\` sort below clean rows.\n\n**Use it for**: a markets table, a screener, "what is moving on Arc". For a single token use \`/arc/token/{address}\`; for search use \`/arc/tokens/search\`.\n\n${ARC_INTRO}`,
  { params: [q("limit", { type: "integer", minimum: 1, maximum: 500, default: 100 }, ""), q("offset", { type: "integer", minimum: 0, maximum: 20000, default: 0 }, ""), q("sort", { type: "string", enum: ["volume", "trades", "traders", "change", "mcap"], default: "volume" }, "Descending."), q("includeUnlisted", { type: "integer", enum: [0, 1], default: 0 }, "1 = include tokens without curated metadata or a logo.")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, sinceHour: int(""), tradersSince: int("Start of the trader-count window."), sort: str(""), offset: int(""), tokens: arr(ref("ArcTokenRow")), total: int(""), updatedAt: UNIX_MS }), ex("/v1/arc/tokens?limit=2")) }, [400, 503]) }));

add("/arc/tokens/search", "get", op(T.arc, "arcSearch", "Search tokens", `Symbol, name or address over every token traded in the last 24 hours. Exact symbol first, then prefix, then name, then substring; listed tokens and volume break ties so the real ARGUS outranks a same-named copy. A pasted contract address always returns that token, even with no 24-hour row. \`coverage\` says how many tokens have a resolved name yet (about a minute after a boot).`,
  { params: [q("q", { type: "string", minLength: 1, maxLength: 64 }, "Symbol, name or address fragment.", true), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 20 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, q: str(""), tokens: arr(ref("ArcTokenRow")), total: int(""), coverage: obj({ resolved: int(""), total: int("") }), updatedAt: UNIX_MS }), ex("/v1/arc/tokens/search?q=argus&limit=2")) }, [400, 503]) }));

add("/arc/trending", "get", op(T.arc, "arcTrending", "Movers of the last two hours", `Tokens scored on volume and trade acceleration over the last two hours, from the hourly rollup. Each row is a full token row plus the score and its inputs.`,
  { params: [q("limit", { type: "integer", minimum: 1, maximum: 50, default: 20 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, window: { type: "string", const: "2h" }, tokens: arr(ref("ArcTrendingRow")), updatedAt: UNIX_MS }), ex("/v1/arc/trending?limit=2")) }, [400, 503]) }));

add("/arc/graduated", "get", op(T.arc, "arcGraduated", "New launches", `Tokens whose first pool on Arc was created inside the window, routable by the engine today and screened: impostor symbols, launch farms (one creator, many pools), no-sell tokens and too few traders are removed and counted in \`screened\`. Newest first, with the launcher named where the registry knows it.\n\n**Use it for**: a "new pairs" feed, launch forensics, an agent watching launches.`,
  { params: [q("hours", { type: "integer", minimum: 1, maximum: 168, default: 48 }, ""), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, hours: int(""), tokens: arr(ref("ArcGraduatedRow")), total: int(""), screened: obj({ not_routable: int(""), impostor: int(""), no_sells: int(""), few_traders: int(""), serial_creator: int(""), no_trades: int(""), no_symbol: int("") }, "How many launches each screen removed."), updatedAt: UNIX_MS }), ex("/v1/arc/graduated?hours=48&limit=2")) }, [400, 503]) }));

add("/arc/launchers", "get", op(T.arc, "arcLaunchers", "Who is creating pools", `Launcher contracts on Arc (Uniswap V4 direct, Uniswap Liquidity Launcher, aka.fun, Argus, Minara.fun, Rapid Launch, …): the pool shapes each one creates, pools per hour and day, distinct creators, and 24-hour tape stats over the pools it created. The Launchpads section lists the named ones.`,
  { params: [q("hours", { type: "integer", minimum: 1, maximum: 168, default: 24 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, hours: int(""), launchers: arr(ref("LauncherStat")), updatedAt: UNIX_MS }), ex("/v1/arc/launchers?hours=24")) }, [400, 503]) }));

add("/arc/attention", "get", op(T.arc, "arcAttention", "What people on Chord are looking at", `Tokens ranked by attention on Chord itself — searches, token-page views, Ask questions and watchlist adds — over 1–7 days. A demand signal, not a price signal.`,
  { params: [q("days", { type: "integer", minimum: 1, maximum: 7, default: 1 }, ""), q("limit", { type: "integer", minimum: 1, maximum: 50, default: 20 }, "")], responses: { 200: ok("", obj({ chain: { type: "integer", const: 5042 }, days: int(""), rows: arr(obj({ token: ADDRESS, score: num(""), ask: int(""), search: int(""), view: int(""), watch: int("") })), updatedAt: UNIX_MS }), ex("/v1/arc/attention?limit=2")) } }));

add("/arc/token/{address}", "get", op(T.arc, "arcToken", "One token: hourly tape and venue split", `The token row plus an hourly series (1–720 hours) and the venue split for the window. Feeds Chord's token page header, volume bars and venue table. A token with no 24-hour row comes back as \`{ address, listed: false }\`.`,
  { params: [p("address", ADDRESS, ""), q("hours", { type: "integer", minimum: 1, maximum: 720, default: 168 }, "Hourly buckets to return.")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, token: { oneOf: [ref("ArcTokenRow"), obj({ address: ADDRESS, listed: { type: "boolean", const: false } })] }, hours: int(""), series: arr(obj({ hour: int(""), volUsd: num(""), buyUsd: num(""), sellUsd: num(""), trades: int(""), buys: int(""), sells: int(""), priceLast: nullable(num("")) }), "Oldest first."), byDex: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num("") })), updatedAt: UNIX_MS }), ex(`/v1/arc/token/${TOK}?hours=2`)) }, [400, 503]) }));

add("/arc/token/{address}/pools", "get", op(T.arc, "arcTokenPools", "Every indexed pool for a token", `V2 pairs, V3 pools and V4 pool ids (with hooks) that hold the token, with the creation block. For LP-oriented ranking use \`/lp/token/{address}/pools\`.`,
  { params: [p("address", ADDRESS, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, token: ADDRESS, pools: arr(obj({ pool: POOL_ID, dex: str(""), kind: { type: "string", enum: ["clmm", "v2", "v4"] }, token0: ADDRESS, token1: ADDRESS, fee: nullable(int("Fee in pips (100 = 0.01%).")), hooks: ADDRESS, createdBlock: int("") })), updatedAt: UNIX_MS }), ex(`/v1/arc/token/${TOK}/pools`)) }, [400, 503]) }));

add("/arc/token/{address}/holders", "get", op(T.arc, "arcTokenHolders", "Holder ledger", `Top balances from Chord's own Transfer-log ledger, each tagged wallet / pool / burn, with the holder count, the share of supply outside pools and burn sinks, and concentration (top 1 / 5 / 10 / 20 / 50 / 100). A token the ledger does not track yet is pinned for tracking and answers \`503 HOLDERS_PENDING\` — retry in a few minutes. A tracked token whose backfill has not reached its creation block answers 200 with \`complete: false\` (never a guess from the tape).`,
  { params: [p("address", ADDRESS, ""), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "Top rows.")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, token: ADDRESS, tracked: bool(""), complete: bool("Backfill reached the creation block — balances are the full ledger."), coverage: obj({ addedBlock: nullable(int("")), floorBlock: nullable(int("")), backfillCursor: nullable(int("")), forwardCursor: nullable(int("")), logs: int("") }), decimals: nullable(int("")), totalSupply: nullable(str("Smallest unit.")), holders: int(""), heldByWalletsPct: nullable(num("")), concentration: nullable(obj({ top1: num(""), top5: num(""), top10: num(""), top20: num(""), top50: num(""), top100: num("") })), top: arr(obj({ holder: ADDRESS, balance: str("Smallest unit."), amount: nullable(num("Whole tokens.")), sharePct: nullable(num("")), kind: { type: "string", enum: ["wallet", "pool", "burn"] } })), updatedAt: UNIX_MS }), ex(`/v1/arc/token/${TOK}/holders?limit=2`)) }, [400, 503]) }));

// Tokens and charts ────────────────────────────────────────────────────────────────────────────
add("/tokens", "get", op(T.tokens, "listTokens", "Curated token list", `Metadata for the tokens Chord routes and labels: address, symbol, name, decimals, logo, tags. On Arc the list leads with the USDC predeploy (the gas token's ERC-20 face) and EURC; on Robinhood Chain with ETH, WETH, USDG and every tokenized stock. Read \`decimals\` here instead of assuming 18.`,
  { params: [chainQ([5042, 4663, 143], { def: 143, required: true })], responses: withErr({ 200: ok("", obj({ tokens: arr(obj({ address: ADDRESS, symbol: str(""), name: str(""), decimals: int(""), logoURI: nullable(str("")), logoUriRaw: nullable(str("")), verified: bool(""), tags: arr({ type: "string" }), liquidityUsd: nullable(num("")) })) }), ex("/v1/tokens?chain=5042")) }, [400]) }));

add("/tokens/market", "get", op(T.tokens, "marketMap", "Price map (Robinhood Chain)", `Price, 24-hour change and volume for every token on the curated list in one call, keyed by lower-cased address — computed from Chord's own index for chain 4663.\n\n**Arc**: use \`/arc/tokens\` (every token with a 24-hour tape, not just the curated list). This endpoint does not take \`chain=5042\`.`,
  { params: [chainQ([4663], { required: true })], responses: { 200: ok("", obj({ market: obj({}, "address → market row", { additionalProperties: obj({ priceUsd: num(""), change24h: num(""), volume24h: num(""), txns24h: int(""), spark: arr({ type: "number" }, "24 hourly closes.") }) }) }), { market: { "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec": { priceUsd: 220.97, change24h: -0.71, volume24h: 34504046, txns24h: 103172, spark: [221.4, 221.1, 220.9] } } }) } }));

add("/tokens/search", "get", op(T.tokens, "searchTokens", "Search the curated list (Robinhood Chain)", `Symbol, name or address over the curated list of chain 4663. Off-list results come back with \`verified: false\`.\n\n**Arc**: use \`/arc/tokens/search\`, which covers every token traded in the last 24 hours.`,
  { params: [q("q", { type: "string" }, "", true), chainQ([4663], { required: true })], responses: { 200: ok("", obj({ tokens: arr(obj({ address: ADDRESS, symbol: str(""), name: str(""), decimals: int(""), verified: bool("") })) }), { tokens: [{ address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", symbol: "NVDA", name: "NVIDIA • Robinhood Token", decimals: 18, verified: true }] }) } }));

add("/tokens/chart/{address}", "get", op(T.tokens, "tokenChart", "Candles", `OHLCV candles from Chord's own tape, address-keyed — one call serves Arc and Robinhood Chain tokens (addresses cannot collide). 200 candles per page; \`before\` pages backwards for unlimited history. A token that is not on a curated list and not a side of an indexed pool is \`404 UNKNOWN_TOKEN\`. For live candles subscribe on \`/v1/ws/live\` (see Streaming).`,
  { params: [p("address", ADDRESS, ""), q("tf", { type: "string", enum: ["1m", "5m", "15m", "1h", "4h", "1d", "1w"], default: "1h" }, "Timeframe."), q("before", UNIX_S, "Return the 200 candles before this time (paging).")],
    responses: withErr({ 200: ok("", obj({ candles: arr(ref("Candle"), "Oldest first."), tf: str(""), source: str("`db` = Chord's tape.") }), ex(`/v1/tokens/chart/${TOK}?tf=1h`)) }, [400, 404, 503]) }));

add("/tokens/trades/{address}", "get", op(T.tokens, "tokenTrades", "Trade tape", `Recent swaps of a token, newest first, with the venue, side, size, price and the attributed wallet. Filter by side, venue, minimum size or wallet; page with \`page\`. \`stats24h\` sums the day.`,
  { params: [p("address", ADDRESS, ""), q("side", { type: "string", enum: ["buy", "sell"] }, ""), q("dex", { type: "string" }, "Venue id."), q("min", { type: "number" }, "Minimum USD."), q("wallet", ADDRESS, ""), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 25 }, ""), q("page", { type: "integer", minimum: 1, default: 1 }, "")],
    responses: withErr({ 200: ok("", obj({ trades: arr(ref("TradeRow")), total: int(""), page: int(""), pageSize: int(""), dexes: arr({ type: "string" }, "Venues seen on this token."), stats24h: obj({ buys: int(""), sells: int(""), buyUsd: num(""), sellUsd: num("") }) }), ex(`/v1/tokens/trades/${TOK}?limit=2`)) }, [400, 404]) }));

add("/tokens/stats/{address}", "get", op(T.tokens, "tokenStats", "Windowed stats", `DexScreener-style windows (5 m, 1 h, 6 h, 24 h): change, transactions, buys/sells, buy/sell volume, makers, buyers, sellers — plus all-time high, 24-hour range, first trade, total transactions and the markets (pools) the token trades on. Cached with stale-while-revalidate, so it answers fast and refreshes in the background.`,
  { params: [p("address", ADDRESS, "")], responses: withErr({ 200: ok("", obj({ priceUsd: nullable(num("")), windows: obj({ m5: ref("StatsWindow"), h1: ref("StatsWindow"), h6: ref("StatsWindow"), h24: ref("StatsWindow") }), liquidityUsd: nullable(num("")), ath: nullable(obj({ priceUsd: num(""), ts: UNIX_S })), range24h: nullable(obj({ high: num(""), low: num("") })), firstTradeTs: nullable(UNIX_S), totalTxns: int(""), markets: arr(obj({ dex: str(""), pool: POOL_ID, txns24h: int(""), vol24h: num(""), makers24h: int("") })) }), ex(`/v1/tokens/stats/${TOK}`)) }, [400, 404]) }));

add("/logo/{chain}/{address}", "get", op(T.tokens, "tokenLogo", "Token logo", `A 128 px WebP of the token's logo, fetched once from the upstream source and cached on disk. A placeholder image (200) when there is none — never a 404, so an \`<img>\` never breaks. Every \`logoURI\` in Arc rows points here.`,
  { params: [p("chain", { type: "integer", enum: [5042, 4663, 143] }, ""), p("address", ADDRESS, "")], responses: { 200: { description: "`image/webp` (or the SVG placeholder).", content: { "image/webp": { schema: { type: "string", format: "binary" } } } } } }));

// Top wallets ──────────────────────────────────────────────────────────────────────────────────
add("/smart-money/top", "get", op(T.wallets, "smartMoneyTop", "Wallets ranked by Smart Score", `Which wallets make money on the chain, from the tape, ranked by a skill-adjusted score rather than raw profit (realized-weighted, luck-corrected, recency-decayed). Routers, executors and bots are removed before ranking (\`botsRemoved\` counts them). On Arc the board moves between rebuilds: a live delta of the last minutes' trades sits on top of the last roll (\`live\`).\n\n**Notes**: \`source=onchain\` is required on 5042 / 4663. The board is rebuilt on a schedule per window (15 min for 24h, hourly for 7d / 30d, 3 h for all) and served from cache in between. \`503 CHAIN_NOT_ENABLED\` until the board is published for the chain.`,
  { params: [chainQ([5042, 4663, 143], { def: 143, required: true }), q("source", { type: "string", enum: ["onchain", "nullterminal"] }, "`onchain` = every venue, from the tape. Required on 5042 and 4663.", true), q("window", { type: "string", enum: ["24h", "7d", "30d", "all"], default: "all" }, ""), q("category", { type: "string", enum: ["all", "memes", "majors"], default: "all" }, ""), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, "")],
    responses: withErr({ 200: ok("", obj({ wallets: arr(ref("SmartWallet")), totalWallets: int("Wallets that qualified after the bot passes."), window: str(""), category: str(""), chain: int(""), source: str(""), indexedToBlock: int("The chain block the tape had reached when this board was built."), updatedAt: UNIX_MS, live: loose("Arc only — the in-memory delta on top of the last roll."), botsRemoved: obj({ cadence: int(""), nonceOrDenylist: int(""), behavior: int("") }), note: str("") }), ex("/v1/smart-money/top?chain=5042&source=onchain&window=7d&limit=2")) }, [400, 503]) }));

// Portfolio ────────────────────────────────────────────────────────────────────────────────────
const PF_NOTE = "Portfolio routes answer an empty 200 shape rather than a 5xx when the tape read fails — treat an empty `tokens` list as \"nothing yet\" and retry later.";
add("/portfolio/{wallet}/pnl", "get", op(T.portfolio, "walletPnl", "Realized and open PnL per token", `Average-cost PnL for one wallet from the tape: realized on sells, unrealized on what is still held at current prices, ROI, and the untracked balance that arrived by transfer (no cost basis, excluded from PnL). Cached with stale-while-revalidate (a day-old answer beats a $0 skeleton).\n\n${PF_NOTE}`,
  { params: [p("wallet", ADDRESS, ""), q("chain", { type: "string", enum: ["5042", "4663", "143", "all"], default: "all" }, "One chain, or `all` to merge chains with a `byChain` breakdown.")],
    responses: withErr({ 200: ok("", obj({ tokens: arr(ref("PnlToken")), realized: num(""), unrealized: num(""), total: num(""), byChain: loose("Only with `chain=all`."), updatedAt: UNIX_MS }), ex(`/v1/portfolio/${WAL}/pnl?chain=5042`)) }, [400]) }));

add("/portfolio/{wallet}/trades", "get", op(T.portfolio, "walletTrades", "Trade history", `The wallet's buys and sells on the chain, newest first — the markers on a portfolio chart.\n\n${PF_NOTE}`,
  { params: [p("wallet", ADDRESS, ""), chainQ([5042, 4663, 143], { def: 143 })], responses: withErr({ 200: ok("", obj({ trades: arr(obj({ t: UNIX_S, side: { type: "string", enum: ["buy", "sell"] }, usd: num(""), tokenAmt: num(""), token: ADDRESS, symbol: nullable(str("")), tx: TX_HASH })), updatedAt: UNIX_MS }), ex(`/v1/portfolio/${WAL}/trades?chain=5042`)) }, [400]) }));

add("/portfolio/{wallet}/pnl-calendar", "get", op(T.portfolio, "walletPnlCalendar", "Realized PnL by day", `Day-by-day realized PnL (UTC days) with the trade count, from the same average-cost model as \`/pnl\`, so the day sums reconcile with \`realized\` by construction.\n\n${PF_NOTE}`,
  { params: [p("wallet", ADDRESS, ""), chainQ([5042, 4663, 143], { def: 143 })], responses: withErr({ 200: ok("", obj({ days: arr(obj({ date: str("YYYY-MM-DD"), realizedUsd: num(""), trades: int("") })), firstDate: nullable(str("")), realizedTotal: num(""), updatedAt: UNIX_MS }), ex(`/v1/portfolio/${WAL}/pnl-calendar?chain=5042`)) }, [400]) }));

// Liquidity ────────────────────────────────────────────────────────────────────────────────────
const LP_CHAIN = chainQ([5042, 4663, 143], { required: true });
add("/lp/overview", "get", op(T.lp, "lpOverview", "Liquidity headline", `The pools page pulse: fees paid to LPs in 24 hours (top 100 pools by fees), the best real yield (≥ 25 traders, not suspect), dollars added and removed, volume, TVL and providers over pools with ≥ $10k TVL, the six hottest pools by fees and the three biggest net inflows. Memoised 30 s.`,
  { params: [LP_CHAIN], responses: withErr({ 200: ok("", obj({ chain: int(""), pools24h: int(""), tvlUsd: num(""), vol24hUsd: num(""), fees24hUsd: num(""), feesPoolsCounted: int(""), lpAdd24hUsd: num(""), lpRemove24hUsd: num(""), providers24h: int(""), best: nullable(obj({ pool: POOL_ID, pair: str(""), token0: ref("TokenLite"), token1: ref("TokenLite"), dex: str(""), feeTvlPct: num(""), aprPct: nullable(num("")), tvlUsd: nullable(num("")) })), hot: arr(obj({ pool: POOL_ID, pair: str(""), token0: ref("TokenLite"), token1: ref("TokenLite"), dex: str(""), feeBps: nullable(num("")), fees24hUsd: num(""), feeTvlPct: nullable(num("")), tvlUsd: nullable(num("")), vol24hUsd: num(""), wallets24h: int("") })), inflow: arr(obj({ pool: POOL_ID, pair: str(""), token0: ref("TokenLite"), token1: ref("TokenLite"), dex: str(""), netUsd: num(""), tvlUsd: nullable(num("")) })), updatedAt: UNIX_MS }), ex("/v1/lp/overview?chain=5042")) }, [400]) }));

add("/lp/pools", "get", op(T.lp, "lpPools", "Pools ranked for a liquidity provider", `Every indexed pool with volume by window, fees (volume × the pool's fee tier), TVL, fee/TVL and an annualised yardstick, LP adds / removes / providers in 24 hours, trader counts, and a 0–100 health score. Pools under $10k TVL are hidden unless \`small=1\`; wash and launch-farm pools are hidden unless \`flagged=1\` (they come back with \`suspect: true\`).\n\n**Use it for**: an LP screener, "where are the fees on Arc", a pool picker for a token.`,
  { params: [LP_CHAIN, q("sort", { type: "string", enum: ["fee_tvl", "vol_24h", "vol_1h", "tvl", "fees_24h", "first_seen", "lp_net_24h", "trades_24h", "score"], default: "fee_tvl" }, ""), q("interval", { type: "string", enum: ["1h", "6h", "24h"], default: "24h" }, "Window the fee/TVL sort uses."), q("minTvl", { type: "number", minimum: 0 }, "Default 10000 unless `small=1`."), q("quote", { type: "string" }, "Anchor symbol filter (e.g. `USDC`)."), q("dex", { type: "string" }, "Venue id filter."), q("search", { type: "string", maxLength: 80 }, "Symbol or address."), q("small", { type: "integer", enum: [0, 1], default: 0 }, "1 = include pools under $10k TVL."), q("flagged", { type: "integer", enum: [0, 1], default: 0 }, "1 = include suspect pools."), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, ""), q("offset", { type: "integer", minimum: 0, maximum: 5000, default: 0 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), sort: str(""), interval: str(""), minTvl: num(""), flagged: bool(""), hidden: int("Rows removed by the filters."), total: int(""), limit: int(""), offset: int(""), pools: arr(ref("PoolListRow")), updatedAt: UNIX_MS }), ex("/v1/lp/pools?chain=5042&limit=2")) }, [400]) }));

add("/lp/pools/{pool}", "get", op(T.lp, "lpPool", "One pool", `The pool row plus a 7-day hourly series, the top providers over 7 days, the health score with its parts and reasons, launch facts (who launched it, how much of the liquidity the launcher holds and has pulled), and \`mint\` — what a wallet needs to add liquidity here (the position manager, the pool key, Permit2, tick spacing).`,
  { params: [p("pool", POOL_ID, ""), LP_CHAIN], responses: withErr({ 200: ok("", { allOf: [ref("PoolListRow"), obj({ chain: int(""), hourly: arr(obj({ hour: int(""), vol: num(""), trades: int(""), price: nullable(num("")) })), topLps: arr(obj({ wallet: ADDRESS, addUsd: num(""), removeUsd: num(""), netUsd: num(""), events: int(""), lastTs: UNIX_S })), health: obj({ score: int(""), parts: obj({ traders: num(""), tvl: num(""), yieldSanity: num(""), lpFlow: num(""), age: num(""), penalties: num("") }), reasons: arr({ type: "string" }) }), launch: nullable(obj({ launcher: nullable(ADDRESS), launcherName: nullable(str("")), creator: nullable(ADDRESS), hooks: nullable(ADDRESS), launchedTs: nullable(UNIX_S), launcherLpAddedUsd: num(""), totalLpAddedUsd: num(""), launcherSharePct: nullable(num("")), launcherLastRemoveTs: nullable(UNIX_S), launcherRemovedUsd: num("") })), mint: nullable(obj({ kind: str(""), manager: nullable(ADDRESS), permit2: ADDRESS, token0: ADDRESS, token1: ADDRESS, feePips: nullable(int("")), tickSpacing: nullable(int("")), hooks: ADDRESS, feeRaw: nullable(int("V4 dynamic-fee pools carry the 0x800000 flag.")), nativeCurrency0: bool("") })), updatedAt: UNIX_MS })] }, ex(`/v1/lp/pools/${POOL}?chain=5042`)) }, [400, 404]) }));

add("/lp/pools/{pool}/positions", "get", op(T.lp, "lpPoolPositions", "Open positions in a pool", `Managed positions (V3 NPM / V4 PositionManager NFTs) open in the pool, largest first, valued live.`,
  { params: [p("pool", POOL_ID, ""), LP_CHAIN, q("limit", { type: "integer", minimum: 1, maximum: 50, default: 20 }, "")], responses: withErr({ 200: ok("", obj({ chain: int(""), pool: POOL_ID, positions: arr(ref("LpPosition")), updatedAt: UNIX_MS }), ex(`/v1/lp/pools/${POOL}/positions?chain=5042&limit=2`)) }, [400]) }));

add("/lp/positions", "get", op(T.lp, "lpPositions", "A wallet's positions", `Every managed position a wallet holds or held: dollars in and out, fees collected, live value and uncollected fees (V3), in-range, PnL on the liquidity leg, age, and the JIT / unreconciled flags; with a summary (open, closed, wins, realized PnL, fees, open value).`,
  { params: [LP_CHAIN, q("owner", ADDRESS, "", true), q("status", { type: "string", enum: ["open", "closed", "all"], default: "all" }, ""), q("token", ADDRESS, "Only positions holding this token."), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), owner: ADDRESS, status: str(""), positions: arr(ref("LpPosition")), summary: obj({ open: int(""), closed: int(""), wins: int(""), winRatePct: nullable(num("")), realizedPnlUsd: num(""), feesUsd: num(""), openValueUsd: num("") }), updatedAt: UNIX_MS }), ex(`/v1/lp/positions?chain=5042&owner=${WAL}&limit=2`)) }, [400]) }));

add("/lp/position/{chain}/{manager}/{id}", "get", op(T.lp, "lpPosition", "One position", `A position by its NFT: the valued row, its events, and a hold-instead comparison (what the same tokens would be worth unpooled).`,
  { params: [p("chain", { type: "integer", enum: [5042, 4663, 143] }, ""), p("manager", ADDRESS, "Position manager contract."), p("id", { type: "string", pattern: "^\\d{1,30}$" }, "Token id.")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), position: ref("LpPosition"), events: arr(obj({ kind: str(""), usd: num(""), feeUsd: num(""), tokenAmt: num(""), anchorAmt: num(""), tx: TX_HASH, ts: UNIX_S, block: int("") })), hold: obj({ tokenIn: num(""), anchorIn: num(""), priceNowUsd: nullable(num("")), holdValueUsd: nullable(num("")), lpValueUsd: nullable(num("")), lpVsHoldUsd: nullable(num("")), basis: str("") }), updatedAt: UNIX_MS })) }, [400, 404]) }));

add("/lp/leaderboard", "get", op(T.lp, "lpLeaderboard", "Best liquidity providers", `LP wallets from the ledger: win rate, fees, pools, expected value per position, average age / invested / monthly profit, profit over 7 / 30 days / all time, the last seven days of profit and what they provide to. Every filter bound is inclusive; unset = off.`,
  { params: [LP_CHAIN, q("sort", { type: "string", enum: ["profit", "win_rate", "avg_age", "positions", "pools", "ev", "avg_invested", "monthly_profit", "fees", "last_activity"], default: "profit" }, ""), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 48 }, ""), q("minIn", { type: "number", default: 20 }, "Ignore positions under this many dollars."), q("minPositions", { type: "integer" }, ""), q("minAgeHours", { type: "number" }, ""), q("minWinRate", { type: "number" }, "Percent."), q("minEv", { type: "number" }, ""), q("minProfit", { type: "number" }, ""), q("minMonthly", { type: "number" }, ""), q("maxFirstTs", UNIX_S, "Only wallets active before this time."), q("lastActiveDays", { type: "number" }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), sort: str(""), minIn: num(""), filters: loose(""), rows: arr(ref("LpLeaderRow")), updatedAt: UNIX_MS }), ex("/v1/lp/leaderboard?chain=5042&limit=2")) }, [400]) }));

add("/lp/events", "get", op(T.lp, "lpEvents", "Liquidity events", `Adds, removes and fee collects on one token, wallet or pool, newest first, each valued in dollars where the pool has an anchor side. One of \`token\`, \`wallet\` or \`pool\` is required.`,
  { params: [LP_CHAIN, q("token", ADDRESS, ""), q("wallet", ADDRESS, ""), q("pool", POOL_ID, ""), q("kind", { type: "string", enum: ["add", "remove", "collect"] }, ""), q("minUsd", { type: "number", minimum: 0 }, ""), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 40 }, ""), q("offset", { type: "integer", minimum: 0, maximum: 10000, default: 0 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), events: arr(ref("LpEvent")), limit: int(""), offset: int(""), updatedAt: UNIX_MS }), ex(`/v1/lp/events?chain=5042&pool=${POOL}&limit=2`)) }, [400]) }));

add("/lp/token/{address}", "get", op(T.lp, "lpToken", "Liquidity flow for a token", `Adds, removes and net dollars over the window, one-sided (token-only) events counted but not valued, just-in-time liquidity (same-transaction add and remove) called out so the totals read right, the top providers and the pools by net flow.`,
  { params: [p("address", ADDRESS, ""), LP_CHAIN, q("hours", { type: "integer", minimum: 1, maximum: 720, default: 24 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), token: ADDRESS, hours: int(""), adds: int(""), addUsd: num(""), removes: int(""), removeUsd: num(""), netUsd: num(""), tokenOnlyAdds: int(""), tokenOnlyRemoves: int(""), jitTxs: int(""), jitUsd: num(""), providers: int(""), top: arr(obj({ wallet: ADDRESS, netUsd: num(""), addedUsd: num(""), removedUsd: num(""), events: int(""), lastTs: UNIX_S })), pools: arr(obj({ pool: POOL_ID, dex: str(""), netUsd: num(""), events: int("") })), updatedAt: UNIX_MS }), ex(`/v1/lp/token/${TOK}?chain=5042&hours=24`)) }, [400]) }));

add("/lp/token/{address}/pools", "get", op(T.lp, "lpTokenPools", "A token's pools by health", `The token's pools ranked by the 0–100 health score with the reasons behind it, and launch facts on Arc (launcher, its share of the liquidity, when it last pulled).`,
  { params: [p("address", ADDRESS, ""), LP_CHAIN], responses: withErr({ 200: ok("", obj({ chain: int(""), token: ADDRESS, pools: arr(obj({ pool: POOL_ID, dex: str(""), kind: str(""), feeBps: nullable(num("")), tvlUsd: nullable(num("")), vol24h: num(""), aprPct: nullable(num("")), score: int(""), reasons: arr({ type: "string" }), launch: nullable(loose("Launch facts (see /lp/pools/{pool}).")) })), updatedAt: UNIX_MS }), ex(`/v1/lp/token/${TOK}/pools?chain=5042`)) }, [400]) }));

add("/lp/plan", "get", op(T.lp, "lpPlan", "Plan a position", `Range bands for a token from its own volatility (tight / balanced / wide, with the share of the last seven days each range would have stayed inside) and each profile backtested on Chord's candles against holding — fees, impermanent loss, exits, time in range. Needs at least 24 hourly candles and an anchored pool (\`404 NOT_ENOUGH_HISTORY\` otherwise). \`young: true\` means under two days of candles — the bands are a launch's noise.`,
  { params: [LP_CHAIN, q("token", ADDRESS, "", true), q("amountUsd", { type: "number", minimum: 1, default: 1000 }, ""), q("days", { type: "integer", minimum: 1, maximum: 30, default: 7 }, "Backtest window."), q("pool", POOL_ID, "Pin a pool; default = the token's best anchored pool.")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), token: ADDRESS, amountUsd: num(""), days: int(""), bands: obj({ priceUsd: num(""), hourlyVolPct: num(""), dailyVolPct: num(""), candles: int(""), young: bool(""), profiles: arr(obj({ profile: { type: "string", enum: ["tight", "balanced", "wide"] }, horizonHours: int(""), lower: num(""), upper: num(""), widthPct: num(""), last7dInsidePct: num("") })), histogram: arr(obj({ lo: num(""), hi: num(""), hours: int("") }), "Where the price spent its hours.") }), sims: arr(obj({ profile: str(""), lower: num(""), upper: num(""), sim: ref("SimResult") })), updatedAt: UNIX_MS }), ex(`/v1/lp/plan?chain=5042&token=${TOK}&amountUsd=1000&days=7`)) }, [400, 404]) }));

add("/lp/simulate", "get", op(T.lp, "lpSimulate", "Backtest one range", `One explicit price range replayed over the last \`days\` of candles in the token's pool: fees earned at the pool's real tier and the position's share, impermanent loss, exits, LP value versus hold.`,
  { params: [LP_CHAIN, q("token", ADDRESS, "", true), q("lower", { type: "number", exclusiveMinimum: 0 }, "Lower price, USD.", true), q("upper", { type: "number" }, "Upper price, USD (> lower).", true), q("amountUsd", { type: "number", minimum: 1, default: 1000 }, ""), q("days", { type: "integer", minimum: 1, maximum: 30, default: 7 }, ""), q("pool", POOL_ID, "")],
    responses: withErr({ 200: ok("", { allOf: [obj({ chain: int(""), token: ADDRESS, updatedAt: UNIX_MS }), ref("SimResult")] }) }, [400, 404]) }));

const WATCH_BODY = obj({ chain: { type: "integer", enum: [5042, 4663, 143] }, wallet: ADDRESS }, undefined, { required: ["chain", "wallet"] });
add("/lp/watch", "get", op(T.lp, "lpWatchStatus", "Watch state and alert inbox", `Whether the wallet's positions are watched, how many Telegram chats receive its alerts, the alert thresholds, the last alerts, and the pools on its watchlist.`,
  { params: [LP_CHAIN, q("wallet", ADDRESS, "", true)], responses: withErr({ 200: ok("", obj({ chain: int(""), wallet: ADDRESS, watched: bool(""), telegramChats: int(""), feeBarUsd: num("Alert when uncollected fees pass this."), drainPct: num("Alert when a pool loses this share of its liquidity."), telegramBot: nullable(str("Bot username for the deep link.")), alerts: arr(obj({ kind: str(""), chain: int(""), wallet: ADDRESS, manager: ADDRESS, tokenId: str(""), pool: nullable(POOL_ID), token: nullable(ADDRESS), symbol: nullable(str("")), text: str(""), usd: nullable(num("")), ts: UNIX_S })), pools: arr(POOL_ID), updatedAt: UNIX_MS })) }, [400]) }));
add("/lp/watch", "post", op(T.lp, "lpWatch", "Watch a wallet's positions", `Turns on in-app alerts for the wallet's positions (out of range, fees to collect, pool draining) and returns a one-hour Telegram deep link that routes the same alerts to a chat.`,
  { body: bodyJson(WATCH_BODY, { chain: 5042, wallet: WAL }), responses: withErr({ 200: ok("", obj({ watched: bool(""), telegramChats: int(""), feeBarUsd: num(""), drainPct: num(""), code: str(""), tgLink: nullable(str("`https://t.me/<bot>?start=lp_<code>`, valid one hour.")) })) }, [400]) }));
add("/lp/watch", "delete", op(T.lp, "lpUnwatch", "Stop watching a wallet", "", { body: bodyJson(WATCH_BODY, { chain: 5042, wallet: WAL }), responses: withErr({ 200: ok("", obj({ watched: { type: "boolean", const: false } })) }, [400]) }));
const WATCH_POOL_BODY = obj({ chain: { type: "integer", enum: [5042, 4663, 143] }, wallet: ADDRESS, pool: POOL_ID }, undefined, { required: ["chain", "wallet", "pool"] });
add("/lp/watch/pool", "post", op(T.lp, "lpWatchPool", "Watch a pool", "Adds a pool to the wallet's watchlist — drain alerts without holding a position.", { body: bodyJson(WATCH_POOL_BODY, { chain: 5042, wallet: WAL, pool: POOL }), responses: withErr({ 200: ok("", obj({ pools: arr(POOL_ID) })) }, [400]) }));
add("/lp/watch/pool", "delete", op(T.lp, "lpUnwatchPool", "Stop watching a pool", "", { body: bodyJson(WATCH_POOL_BODY, { chain: 5042, wallet: WAL, pool: POOL }), responses: withErr({ 200: ok("", obj({ pools: arr(POOL_ID) })) }, [400]) }));
add("/lp/status", "get", op(T.lp, "lpStatus", "Liquidity lane state", "Per-chain cursors, heads, last tick, pool-stat floors and position counts for the liquidity indexer — the freshness check for everything under `/lp`.", { responses: { 200: ok("", loose("Lane state per chain (`lanes`, `pools`, `positions`)."), ex("/v1/lp/status")) } }));

// Points ───────────────────────────────────────────────────────────────────────────────────────
add("/points/rules", "get", op(T.points, "pointsRules", "Points program rules", `Season, current week, points per dollar, the weekly pool, the daily cap, streak multipliers, referral bonuses and the tiers — and the plain-English rules of what counts. Only swaps executed through Chord on Arc score.`,
  { responses: { 200: ok("", obj({ chain: int(""), season: int(""), seasonStart: UNIX_S, currentWeek: int(""), weekLengthSec: int(""), pointsPerUsd: num(""), minTradeUsd: num(""), weekPool: num(""), dayCapUsd: num(""), referredBonusPct: num(""), referralBonusPct: num(""), streak: arr(obj({ days: int(""), multiplier: num("") })), counts: str(""), size: str(""), pool: str(""), tiers: arr(obj({ name: str(""), topRanks: nullable(int("")), topPct: nullable(num("")), note: str("") })), provisional: str("") }), ex("/v1/points/rules")) } }));
add("/points/leaderboard", "get", op(T.points, "pointsLeaderboard", "Weekly or season leaderboard", `Wallets ranked by points for one week or the whole season, with base points, referral and streak bonuses, volume, trades, days active and tier. \`503 NOT_ENABLED\` while the program is off on the deployment.`,
  { params: [q("scope", { type: "string", enum: ["week", "season"], default: "week" }, ""), q("week", { type: "string" }, "Week number or `current`."), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, "")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), season: int(""), scope: str(""), week: nullable(int("")), weekBounds: nullable(obj({ from: UNIX_S, to: UNIX_S })), seasonStart: UNIX_S, currentWeek: int(""), weekPool: num(""), rows: arr(obj({ rank: int(""), wallet: ADDRESS, points: num(""), basePoints: num(""), referralBonus: num(""), streakBonus: num(""), volumeUsd: num(""), trades: int(""), daysActive: int(""), tier: nullable(str("")), lastTradeTs: UNIX_S })), totalWallets: int(""), totalPoints: num(""), totalVolumeUsd: num(""), indexedToBlock: nullable(int("")), updatedAt: UNIX_MS })) }, [400, 503]) }));
add("/points/wallet/{address}", "get", op(T.points, "pointsWallet", "One wallet's standing", "Season and current-week points, rank, tier and volume for a wallet.", { params: [p("address", ADDRESS, "")], responses: withErr({ 200: ok("", loose("`{ chain, season, wallet, seasonStart, currentWeek, weekPool, season_: {points, basePoints, referralBonus, streakBonus, volumeUsd, trades, rank, tier, totalWallets}, week: {…} }`")) }, [400, 503]) }));

// Ask ──────────────────────────────────────────────────────────────────────────────────────────
add("/ask/status", "get", op(T.ask, "askStatus", "Is the analyst on", "Whether Ask is enabled, whether guest sessions are open, and today's token budget.", { responses: { 200: ok("", obj({ enabled: bool(""), chain: { type: "integer", const: 5042 }, guest: bool(""), budget: obj({ used: int(""), total: int("") }) }), ex("/v1/ask/status")) } }));
add("/ask", "post", op(T.ask, "ask", "Ask the analyst",
`Chord's analyst over the Arc index and the router — 40+ tools (trending, a token's flow, holders and risk, support and resistance with an entry ladder, top traders on a token, a wallet's PnL and trades, largest prints, launches, depth, a bridge quote, position sizing, read-only SQL over the index). Returns the answer, source links, an optional route card, tables and charts the analysis produced, and a report when one was built.

**Auth**: a developer API key (\`X-API-Key\`) or a Google session bearer. Metered per key per day against the deployment's token budget; 8 questions a minute per caller.

**Agents**: send \`"stream": false\` for one JSON answer (5–40 s). Without it the response is \`text/event-stream\` with \`status\` events (which tool is running), one \`answer\` event, then \`done\`.`,
  { security: [{ ApiKey: [] }, { Session: [] }],
    body: bodyJson(obj({ question: { type: "string", minLength: 1, maxLength: 1000 }, stream: { type: "boolean", description: "false = one JSON response instead of SSE." }, history: arr(obj({ role: { type: "string", enum: ["user", "assistant"] }, content: { type: "string", maxLength: 4000 } }), "Up to 12 prior turns."), wallet: { ...ADDRESS, description: "The caller's wallet, so \"my PnL\" resolves." } }, undefined, { required: ["question"] }), { question: "What is moving on Arc right now, and is ARGUS still being bought by real wallets?", stream: false }),
    responses: withErr({ 200: ok("With `stream: false`: the whole answer. Otherwise `text/event-stream`.", obj({ text: str("The answer, Markdown."), citations: arr(loose("Source links (endpoint + parameters the answer read).")), quote: nullable(loose("A route card when the question implied a trade.")), artifact: nullable(loose("Chart levels, ladder, zones, report link.")), walletArtifact: nullable(loose("")), viz: arr(loose("Tables and charts (`kind`: table · bar · line · donut).")), toolsUsed: arr({ type: "string" }), tokens: int("Model tokens spent.") })) }, [400, 401, 429, 503]) }));
add("/ask/picks", "get", op(T.ask, "askPicks", "Ask Picks board", "The analyst's current picks (rebuilt every four hours over tokens with real activity): side, score, confidence, target and invalidation with how each was set, the reasons for and against, and the facts behind them — plus the seven-day track record.", { responses: { 200: ok("", obj({ chain: { type: "integer", const: 5042 }, computedAt: nullable(UNIX_S), picks: arr(obj({ ts: UNIX_S, token: ADDRESS, symbol: nullable(str("")), side: { type: "string", enum: ["bullish", "bearish"] }, score: num(""), confidence: { type: "string", enum: ["low", "medium", "high"] }, priceUsd: num(""), target: num(""), invalidation: num(""), levels: obj({ target: num(""), targetFrom: str(""), invalidation: num(""), invalidationFrom: str("") }), why: arr({ type: "string" }), against: arr({ type: "string" }), facts: loose("") })), trackRecord7d: nullable(obj({ graded: int(""), targetHits: int(""), stopHits: int(""), expired: int(""), open: int(""), avgMovePct: num(""), hitRatePct: num("") })) }), ex("/v1/ask/picks")) } }));
add("/ask/report", "post", op(T.ask, "askReport", "Build a research note", "Builds Chord's three-page research note for a token (HTML → PDF in the browser, plus Markdown) and returns links good for seven days.", { security: [{ Session: [] }], body: bodyJson(obj({ token: str("Address or symbol on Arc."), summary: { type: "string", maxLength: 4000, description: "Optional analyst text to place on the first page." } }, undefined, { required: ["token"] }), { token: "ARGUS" }), responses: withErr({ 200: ok("", obj({ id: str(""), url: str("HTML."), mdUrl: str("Markdown.") })) }, [400, 401, 404, 429, 503]) }));
add("/ask/report/{id}", "get", op(T.ask, "askReportGet", "Fetch a report", "The note as HTML, or Markdown with a `.md` suffix. Public by unguessable id, seven days.", { params: [p("id", { type: "string" }, "Report id, optionally with `.md`.")], responses: { 200: { description: "`text/html` or `text/markdown`.", content: { "text/html": { schema: { type: "string" } }, "text/markdown": { schema: { type: "string" } } } }, 404: ERR[404] } }));
add("/ask/export/{id}", "get", op(T.ask, "askExport", "Fetch a CSV export", "A table the analyst exported, as CSV (one hour).", { params: [p("id", { type: "string" }, "Export id, optionally with `.csv`.")], responses: { 200: { description: "`text/csv`.", content: { "text/csv": { schema: { type: "string" } } } }, 404: ERR[404] } }));

// Bridge ───────────────────────────────────────────────────────────────────────────────────────
add("/bridge2/config", "get", op(T.bridge, "bridge2Config", "CCTP chain table", `Circle CCTP V2 fast transfer to and from Arc: the chains and domains, USDC addresses, the TokenMessenger / MessageTransmitter contracts, and the Arc-side relayer (address, balance, enabled). The browser signs the burn; Chord proxies the attestation and relays the Arc mint.`,
  { responses: { 200: ok("", obj({ provider: { type: "string", const: "cctp-v2" }, fastFinalityThreshold: int(""), arcDomain: int(""), contracts: obj({ tokenMessengerV2: ADDRESS, messageTransmitterV2: ADDRESS }), chains: arr(obj({ chainId: int(""), domain: int(""), name: str(""), usdc: ADDRESS })), relayer: obj({ address: nullable(ADDRESS), arcBalance: nullable(str("Wei.")), enabled: bool("") }) }), ex("/v1/bridge2/config")) } }));
add("/bridge2/fee", "get", op(T.bridge, "bridge2Fee", "CCTP fee", "Circle's minimum fee for a fast and a standard transfer between two domains, in basis points.", { params: [q("src", { type: "integer" }, "Source CCTP domain.", true), q("dst", { type: "integer" }, "Destination CCTP domain.", true)], responses: withErr({ 200: ok("", obj({ src: int(""), dst: int(""), fastBps: num(""), standardBps: num("") })) }, [400, 503]) }));
add("/bridge2/status", "get", op(T.bridge, "bridge2Status", "Attestation status", "Iris status for a burn transaction: `not_found`, `pending` or `complete` with the message and attestation when ready.", { params: [q("srcDomain", { type: "integer" }, "", true), q("tx", TX_HASH, "The burn transaction.", true)], responses: withErr({ 200: ok("", obj({ status: { type: "string", enum: ["not_found", "pending", "complete"] }, srcDomain: int(""), tx: TX_HASH, message: nullable(str("")), attestation: nullable(str("")), eventNonce: nullable(str("")), decoded: nullable(loose("")) })) }, [400, 503]) }));
add("/bridge2/relay", "post", op(T.bridge, "bridge2Relay", "Relay the Arc mint", "Once attested, Chord's relayer submits `receiveMessage` on Arc so the recipient needs no gas there. `409 NOT_ATTESTED` until Iris completes; `429 DAILY_CAP`; `503 RELAYER_OFF`.", { body: bodyJson(obj({ srcDomain: int(""), tx: TX_HASH }, undefined, { required: ["srcDomain", "tx"] }), { srcDomain: 6, tx: "0x…" }), responses: withErr({ 200: ok("", obj({ ok: { type: "boolean", const: true }, txHash: TX_HASH })), 409: errRes("`NOT_ATTESTED` or `IN_FLIGHT`.") }, [400, 429, 502, 503]) }));

const PROVIDER_Q = q("provider", { type: "string", enum: ["lifi", "relay"] }, "Bridge provider. Chord uses `lifi`.");
add("/crosschain/config", "get", op(T.bridge, "crosschainConfig", "Bridge providers and chains", "Whether the provider is enabled, its app fee, the origin chains this deployment offers, and the destination chains with display names, native symbols, explorers and icons.", { params: [PROVIDER_Q, q("origin", { type: "integer" }, "Exclude this chain from the list.")], responses: { 200: ok("", obj({ enabled: bool(""), provider: str(""), appFeeBps: num(""), origins: arr({ type: "integer" }), origin: nullable(int("")), chains: arr(obj({ id: int(""), name: str(""), displayName: str(""), nativeSymbol: str(""), explorerUrl: str(""), featured: bool(""), iconUrl: nullable(str("")) })) }), ex("/v1/crosschain/config?provider=lifi")) } }));
add("/crosschain/currencies", "get", op(T.bridge, "crosschainCurrencies", "Bridgeable tokens on a chain", "Tokens the provider can move on a chain, filtered by a search term.", { params: [q("chainId", { type: "integer" }, "", true), q("q", { type: "string", maxLength: 40 }, "Symbol or name (≥ 2 characters)."), PROVIDER_Q], responses: withErr({ 200: ok("", obj({ chainId: int(""), provider: str(""), currencies: arr(loose("Token rows (address, symbol, name, decimals, logo).")) })) }, [400, 503]) }));
add("/crosschain/quote", "post", op(T.bridge, "crosschainQuote", "Bridge quote", "A cross-chain quote from the provider: the steps, fees and the transactions to sign on the origin chain (an approve step is added when the origin token is an ERC-20). Poll `/crosschain/status` with the deposit hash.", { body: bodyJson(obj({ user: ADDRESS, originChainId: { type: "integer", default: 143 }, destinationChainId: int(""), originCurrency: ADDRESS, destinationCurrency: ADDRESS, amount: WEI, slippageBps: { type: "integer", minimum: 10, maximum: 500, default: 100 }, recipient: ADDRESS, provider: { type: "string", enum: ["lifi", "relay"] } }, undefined, { required: ["user", "destinationChainId", "originCurrency", "destinationCurrency", "amount"] }), { user: WAL, originChainId: 8453, destinationChainId: 5042, originCurrency: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", destinationCurrency: USDC, amount: "100000000", slippageBps: 100, provider: "lifi" }), responses: withErr({ 200: ok("", loose("`{ provider, requestId, steps[], fees, details, checkEndpoint, txns[] }` — provider-shaped; sign `txns` in order.")) }, [400, 429, 502, 503]) }));
add("/crosschain/status", "get", op(T.bridge, "crosschainStatus", "Bridge status", "Status of a bridge by its request id or deposit hash: `waiting` · `depositing` · `pending` · `submitted` · `success` · `delayed` · `refund` · `failure` · `unknown`.", { params: [q("requestId", { type: "string", pattern: "^0x[a-fA-F0-9]{64}$" }, "Request id (or the deposit tx hash on LI.FI).", true), PROVIDER_Q, q("fromChain", { type: "integer" }, ""), q("toChain", { type: "integer" }, "")], responses: withErr({ 200: ok("", obj({ status: { type: "string", enum: ["waiting", "depositing", "pending", "submitted", "success", "delayed", "refund", "failure", "unknown"] }, substatus: str(""), inTxHashes: arr({ type: "string" }), txHashes: arr({ type: "string" }), explorerLink: str(""), updatedAt: UNIX_MS })) }, [400, 429, 502, 503]) }));

// Robinhood Chain data ─────────────────────────────────────────────────────────────────────────
const RH_INTRO = "Chain 4663 only; takes no `chain` parameter. Served from Chord's rollup tables, never from a raw scan. `503 NOT_READY` until the rollup has run.";
add("/rh/status", "get", op(T.rh, "rhStatus", "Rollup freshness", RH_INTRO, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, enabled: bool(""), recentAt: nullable(UNIX_S), staleSec: nullable(int("")), floorHour: nullable(int("")), genesisHour: nullable(int("")), backfillComplete: bool(""), updatedAt: UNIX_MS }), ex("/v1/rh/status")) }, [503]) }));
add("/rh/overview", "get", op(T.rh, "rhOverview", "Chain totals", `Last 24 hours, venue share, 24 hourly buckets and up to 30 daily rows. ${RH_INTRO}`, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, last24h: obj({ volUsd: num(""), swaps: int(""), tokens: int(""), sinceHour: int("") }), venues24h: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), tokens: int(""), sharePct: num("") })), hourly24: arr(obj({ hour: int(""), volUsd: num(""), swaps: int("") })), daily: arr(obj({ day: int(""), swaps: int(""), volUsd: num(""), tokens: int(""), wallets: int(""), venues: int("") })), coverage: ref("Coverage"), updatedAt: UNIX_MS }), ex("/v1/rh/overview")) }, [503]) }));
add("/rh/venues", "get", op(T.rh, "rhVenues", "Venue share over a window", RH_INTRO, { params: [q("days", { type: "integer", minimum: 1, maximum: 180, default: 30 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, days: int(""), venues: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num(""), series: arr(obj({ day: int(""), volUsd: num(""), trades: int(""), tokens: int("") })) })), totals: obj({ volUsd: num(""), trades: int("") }) })) }, [400, 503]) }));
add("/rh/tokens", "get", op(T.rh, "rhTokens", "Every token traded in the last 24 hours", `Price, change, volume split, trade counts and attributed traders. Unlisted tokens (no curated metadata or logo) are hidden unless asked for. ${RH_INTRO}`, { params: [q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, ""), q("sort", { type: "string", enum: ["volume", "trades", "traders", "change"], default: "volume" }, ""), q("includeUnlisted", { type: "integer", enum: [0, 1], default: 0 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, sinceHour: int(""), tradersSince: int(""), sort: str(""), tokens: arr(ref("RhTokenRow")), total: int(""), updatedAt: UNIX_MS }), ex("/v1/rh/tokens?limit=2")) }, [400, 503]) }));
add("/rh/token/{address}", "get", op(T.rh, "rhToken", "One token: hourly tape and venue split", RH_INTRO, { params: [p("address", ADDRESS, ""), q("hours", { type: "integer", minimum: 1, maximum: 720, default: 168 }, "")], responses: withErr({ 200: ok("", obj({ token: obj({ address: ADDRESS, symbol: nullable(str("")) }), series: arr(obj({ hour: int(""), volUsd: num(""), buyUsd: num(""), sellUsd: num(""), trades: int(""), buys: int(""), sells: int(""), priceLast: nullable(num("")) })), byDex: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num("") })) })) }, [400, 503]) }));
add("/rh/stocks", "get", op(T.rh, "rhStocks", "Tokenized stocks", `Every tokenized stock and ETF on chain 4663 with its 24-hour tape, NAV basis where the issuer publishes a rate, and the share of the last seven days that traded outside the NYSE session. ${RH_INTRO}`, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, sinceHour: int(""), tradersSince: int(""), stocks: arr(ref("RhStockRow")), note: str(""), updatedAt: UNIX_MS }), ex("/v1/rh/stocks")) }, [503]) }));

// Streaming (documented as operations so they appear in the reference; protocol detail lives in Concepts → Streaming) ──
add("/stream/market", "get", op(T.stream, "streamMarket", "Server-sent events: prices", `One \`text/event-stream\` feed, no key, EventSource-friendly with automatic reconnect. Events: \`rh-ticker\` (fresh prices for chain 4663, about every 10 s, only addresses whose price moved), \`ticker\` / \`whales\` / \`defi\` (Monad), \`ping\` every 5 s. Capacity 500 clients (\`503\` beyond). Arc prices stream over the WebSocket \`prices\` channel instead — see Concepts → Streaming.`,
  { responses: { 200: { description: "`text/event-stream`", content: { "text/event-stream": { schema: { type: "string" }, example: 'event: rh-ticker\ndata: {"items":[{"address":"0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec","priceUsd":220.97,"change24h":-0.71}]}\n\nevent: ping\ndata: 1789891855\n' } } }, 503: errRes("At capacity.") } }));
add("/ws/live", "get", op(T.stream, "wsLive", "WebSocket: live candles, trades and Arc prices", `Upgrade to a WebSocket. No key, rate-limit exempt, up to 8 channels per connection. Subscribe with \`{op:"sub", channel:"candles", token, tf}\`, \`{op:"sub", channel:"trades", token}\` or \`{op:"sub", channel:"prices", chain:5042}\`; the server pushes \`candle\`, \`trades\` and \`prices\` frames, \`ping\` every 25 s, and \`error\` with a code (\`bad_op\` · \`bad_token\` · \`bad_tf\` · \`bad_chain\` · \`channel_cap\`). Full protocol under Concepts → Streaming.`,
  { responses: { 101: { description: "Switching protocols." }, 503: errRes("`WS_LIVE_DISABLED` or at capacity.") } }));

// Account and health ───────────────────────────────────────────────────────────────────────────
add("/me", "get", op(T.account, "me", "Your key's plan and usage", "The tier, limits and usage (today, this month) behind an API key. Keys are created on getchord.xyz/developer after a Google sign-in.", { security: [{ ApiKey: [] }], responses: withErr({ 200: ok("", obj({ email: nullable(str("")), tier: { type: "string", enum: ["free", "builder", "pro"] }, limits: obj({ rpm: int(""), monthly: int(""), priceUsd: num(""), label: str("") }), usage: obj({ today: int(""), month: int("") }) }), { email: "you@example.com", tier: "free", limits: { rpm: 60, monthly: 100000, priceUsd: 0, label: "Free" }, usage: { today: 41, month: 1209 } }) }, [401]) }));
add("/health", "get", op(T.account, "health", "Service health", "Engine, cache and pool-sync state. `503` when the routing engine is unreachable.", { responses: withErr({ 200: ok("", obj({ status: str(""), version: str(""), uptime: num("Seconds."), engine: obj({ status: str(""), latencyMs: int("") }), redis: obj({ status: str("") }), poolCount: int(""), lastSyncBlock: int("") }), ex("/v1/health")) }, [503]) }));

// ── document ──────────────────────────────────────────────────────────────────────────────────
const doc = {
  openapi: "3.1.0",
  info: {
    title: "Chord API",
    version: "2026-09-20",
    summary: "Trade, data and agent endpoints for Arc (5042) and Robinhood Chain (4663).",
    description: `Chord is a non-custodial trading app and on-chain data index. The API has three kinds of endpoint:

- **Trade**: \`/quote\` finds the best route across every venue on the chain; \`/swap\` turns it into a transaction you sign yourself. Chord never holds funds or keys.
- **Read**: every swap on the chain, rolled up by token, venue and hour, from Chord's own index — tokens, launches, holders, top wallets, portfolio PnL, liquidity positions and pools. No key needed.
- **Agent**: the analyst (\`/ask\`) and the streams.

Amounts are decimal strings in the token's smallest unit. Timestamps are Unix seconds unless the field is \`updatedAt\` (milliseconds). Reads answer anonymous callers at 60 requests a minute per IP; an \`X-API-Key\` header raises that to your plan. Every non-2xx body is \`{ error, message }\`.`,
    contact: { name: "Chord", url: "https://getchord.xyz/developer" },
    "x-logo": { url: "https://getchord.xyz/chord/pwa-192x192.png" },
  },
  servers: [{ url: "https://api.getchord.xyz/v1", description: "Production" }],
  tags: [
    { name: T.swap, description: "Best-route quotes across every venue on the chain, and the unsigned transaction to execute them." },
    { name: T.arc, description: "Arc (chain 5042): chain totals, every token traded, launches, launchers, holders — from Chord's own rollup and index tables." },
    { name: T.tokens, description: "Curated lists, candles, trade tapes, windowed stats and logos. Address-keyed routes serve both chains." },
    { name: T.wallets, description: "Wallets ranked from the tape by a skill-adjusted score, with routers and bots removed." },
    { name: T.portfolio, description: "Average-cost PnL, trade history and a daily calendar for any wallet." },
    { name: T.lp, description: "Liquidity: events, pools ranked for providers, positions valued live, LP leaderboard, range planning and backtests, alerts." },
    { name: T.points, description: "The Chord points program on Arc." },
    { name: T.ask, description: "The analyst agent over the Arc index, its picks and research notes." },
    { name: T.bridge, description: "Circle CCTP fast transfer to Arc, and LI.FI routes from 60+ chains." },
    { name: T.rh, description: "Robinhood Chain (chain 4663): chain totals, tokens and tokenized stocks from the rollup tables." },
    { name: T.stream, description: "Server-sent events and the public WebSocket." },
    { name: T.account, description: "Your key, and the service's own health." },
  ],
  paths,
  components,
};

const out = JSON.stringify(doc, null, 2);
writeFileSync(join(here, "chord.json"), out);
mkdirSync(join(here, "..", "public"), { recursive: true });
writeFileSync(join(here, "..", "public", "openapi.json"), out);
const ops = Object.values(paths).reduce((n, m) => n + Object.keys(m).length, 0);
console.log(`openapi/chord.json: ${Object.keys(paths).length} paths, ${ops} operations, ${Object.keys(components.schemas).length} schemas`);
