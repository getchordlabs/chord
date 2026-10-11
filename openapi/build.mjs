// Builds openapi/chord.json (OpenAPI 3.1) — the Chord API contract that starlight-openapi turns into
// the "API reference" section, and that is served verbatim at /docs/openapi.json for codegen and
// LLM tool-use. Hand-maintained, like packages/api/src/routes/openapi.ts (the NullTerminal spec):
// the route surface changes rarely and rewiring every Hono route through zod-openapi is not worth
// the risk. Examples come from openapi/examples.json — real responses captured from
// api.getchord.xyz (arrays trimmed to two rows), so a reader sees the true shape, not a sketch.
//
// Scope = the Chord surface: everything the Chord app calls on chains 5042 (Arc) and 4663
// (Robinhood Chain), the chain-keyed data routes for Avalanche (43114), Base (8453) and BNB Chain (56)
// under /chains/{chain}/* (routes/chains.ts), Solana's read-only tape under /chains/solana/* (routes/solana.ts), plus the
// developer/agent endpoints. Monad-only routes and
// the admin/app consoles are left out on purpose.
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
const CHAIN_DESC = { 5042: "Arc", 4663: "Robinhood Chain", 143: "Monad", 43114: "Avalanche C-Chain", 8453: "Base", 56: "BNB Chain" };
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
  422: errRes("The request is valid but cannot be served as asked (`INPUT_NOT_SIMULATABLE` on `/meta/*`: a route exists, but the input token cannot be supplied in a simulation and the taker does not hold it — hold the input and ask again)."),
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

const IngestFloor = obj({
  minTradeUsd: num("Trades under this USD value (at index time) are not in the index, so every count, volume and candle covers trades at or above it. 0 = every priced trade."),
  history: arr(obj({ usd: num("Floor in force."), fromTs: UNIX_S }), "Floors in force over time, oldest first. Empty when the chain was never floored. Raising a floor does not remove older, smaller rows."),
}, "The tape's ingest floor. BNB Chain runs at $100 today; Avalanche and Base at 0.");

const ChainCoverage = obj({ recentAt: UNIX_S, stale: bool("True when the last rollup pass is more than 30 minutes old.") }, "When the rollup last ran.");

const ChainVenueShare = obj({ dex: str("Venue id."), volUsd: num(""), trades: int(""), tokens: int(""), sharePct: num("") }, "One venue's share of the window.");

const ChainTokenRow = obj({
  address: ADDRESS, symbol: nullable(str("Read from the contract. Null while unresolved.")), name: nullable(str("")), decimals: nullable(int("")),
  logoURI: { type: "null", description: "Always null on these chains for now." },
  priceUsd: nullable(num("Last print on the token's busiest venue, USD.")), change24hPct: nullable(num("")),
  volume24h: num("USD, every venue, trades at or above the ingest floor."), buyVolume24h: num(""), sellVolume24h: num(""),
  trades24h: int(""), buys24h: int(""), sells24h: int(""),
  dominantDex: nullable(str("Venue id with the most 24-hour volume.")), lastTradeTs: UNIX_S,
}, "One token on a chain-keyed chain with its 24-hour tape. No curated list, no honesty flags, no trader counts yet.");

const META_CHAINS = [143, 4663, 5042, 43114, 8453, 56];
const MetaAttempt = obj({
  provider: str("`chord`, `kyberswap`, `monorail`, `lifi` or `relay`."),
  status: str("`ok`, or why this provider did not produce the answer: `no_route`, `timeout`, `http_error`, `rate_limited`, `invalid_response`, `not_allowlisted`, `calldata_mismatch`, `min_out_too_low`, `value_gap`, `unsafe_token`, `simulation_failed`, `unverified`, `breaker_open`, `skipped`; for Chord also `engine_error`, `engine_timeout`, `engine_down`, `route_refused`, `build_failed`, `chain_not_live`."),
  ms: int("Time spent on this provider."), error: nullable(str("Short reason from a fixed vocabulary, never provider text.")),
}, "One provider that was asked, in order.");
const MetaQuote = obj({
  chain: int("Chain id."), tokenIn: ADDRESS, tokenOut: ADDRESS, amountIn: WEI, taker: nullable({ ...ADDRESS, description: "The wallet the transaction was built and simulated for; null on a price-only quote." }),
  slippageBps: int("The slippage `minAmountOut` reflects."),
  provider: nullable(str("Who answered: `chord` (Chord's own router), `kyberswap`, `monorail`, `lifi`, `relay`. `null` = no provider has a route.")),
  fallbackReason: nullable(str("`null` when Chord answered. Otherwise why it did not: `no_route`, `insufficient_liquidity`, `engine_error`, `engine_timeout`, `engine_down`, `value_guard`, `taxed_token`, `route_stale`, `chain_not_live`, `build_failed`, `simulation_failed`.")),
  attempts: arr(ref("MetaAttempt"), "Every provider asked, in order."),
  amountOut: { ...WEI, description: "What the taker receives after every fee, smallest unit of `tokenOut`. (`/quote`'s `outputAmount` is before Chord's fee; this is after.)" },
  minAmountOut: { ...WEI, description: "The minimum the transaction enforces, from the slippage you asked for." },
  priceImpactPct: nullable(str("Percent, when the provider states one.")),
  valueLossPct: nullable(num("Output value against input value at Chord's own prices, percent (negative = worth more). `null` when Chord has no reliable price for a side: see `safety` and `warnings`.")),
  feeBps: int("Chord path: Chord's protocol fee on the output. Fallback: the integrator fee Chord added (0 today); the provider's own fees are already inside `amountOut`."),
  feeRecipient: nullable(ADDRESS),
  route: obj({ venues: arr(str(""), "Venue names.") }),
  tx: nullable(obj({ to: ADDRESS, data: str("Calldata."), value: WEI, gas: nullable(str("Gas limit to sign with.")), chainId: int("") }, "The UNSIGNED transaction. `null` without `taker`. `to` is the Chord router when `provider` is `chord`, the provider's own router otherwise.")),
  approval: nullable(obj({ token: ADDRESS, spender: ADDRESS, amount: WEI }, "The approval to send first. `null` for a native input or when the taker's allowance already covers the amount.")),
  simulation: nullable(obj({ ok: nullable(bool("`true` = ran and delivered at least `minAmountOut`; `null` = no verdict (only ever returned on the Chord path).")), amountOut: WEI, gasUsed: int(""), revert: str(""), reason: str("") }, "The transaction run as the taker (with the input supplied when the taker does not hold it), measuring the taker's own balance change. `null` without `taker`.")),
  safety: nullable(obj({ source: str("`goplus`"), token: ADDRESS, worstFlag: str("`none`, `low`, `medium`, `high`."), honeypot: nullable(bool("")), buyTaxPct: nullable(num("")), sellTaxPct: nullable(num("")), risks: arr(str("")) }, "A security scan of the unknown token, present when the value check could not run on a fallback answer.")),
  warnings: arr(str(""), "`INSUFFICIENT_BALANCE`, `UNPRICED`, `OUTPUT_WRAPPED`, `NO_ROUTE`, and on a price-only fallback `PRICE_CHECKED` (built and simulated for a placeholder wallet) or `UNVERIFIED_PRICE` (built, not simulatable) — each followed by a sentence."),
  quoteId: str("Pass to `POST /meta/swap` within 2 minutes."), expiresAt: UNIX_S,
}, "The same shape whichever provider answered.");

const components = {
  securitySchemes: {
    ApiKey: { type: "apiKey", in: "header", name: "X-API-Key", description: "Optional on every read. A key from getchord.xyz/developer raises the rate limit to your plan and meters usage per key. Required for `?only=` on quotes and for the Ask agent API." },
    Session: { type: "http", scheme: "bearer", description: "A Google sign-in session minted by the app (`nts_…`). Only the browser surfaces use it; agents use `ApiKey`." },
  },
  schemas: {
    Error: obj({ error: str("Stable machine code, e.g. `INVALID_PARAMS`, `NOT_READY`, `RATE_LIMIT_EXCEEDED`."), message: str("For humans."), statusCode: int("HTTP status, when included.") }, "Every non-2xx body.", { required: ["error"], example: { error: "INVALID_PARAMS", message: "amount must be an integer string in the token's smallest unit" } }),
    Coverage, TokenLite, ArcTokenRow, ArcTrendingRow, ArcGraduatedRow, RhTokenRow, RhStockRow, RouteLeg, QuoteResponse, SwapTx, MetaAttempt, MetaQuote, Candle, TradeRow, StatsWindow, SmartWallet, PnlToken, LpEvent, PoolListRow, LpPosition, LpLeaderRow, SimResult, LauncherStat, IngestFloor, ChainCoverage, ChainTokenRow, ChainVenueShare,
  },
};

// ── paths ─────────────────────────────────────────────────────────────────────────────────────
const paths = {};
const add = (path, method, operation) => { (paths[path] ??= {})[method] = operation; };

const T = {
  swap: "Quote and swap",
  meta: "Meta aggregator",
  arc: "Arc data",
  tokens: "Tokens and charts",
  wallets: "Top wallets",
  portfolio: "Portfolio",
  lp: "Liquidity",
  points: "Points",
  ask: "Ask agent",
  bridge: "Bridge",
  rh: "Robinhood Chain data",
  chains: "Avalanche, Base, BNB Chain",
  sol: "Solana data",
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

// Meta aggregator ──────────────────────────────────────────────────────────────────────────────
const META_USDC_BASE = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", META_WETH_BASE = "0x4200000000000000000000000000000000000006";
const META_TAKER = "0x00000000000000000000000000000000000c0ffe";
const META_POLICY = `**Policy**
1. Chord's own router is always asked first, with its normal budget.
2. A fallback is asked only when Chord fails: the engine timed out, errored or is down; there is no route; Chord refuses the route itself (value guard, taxed token, stale bonding-curve route); the chain's router is not live; or the built transaction fails simulation. A better price elsewhere is not a reason. A user error (unknown token, bad amount) never falls back.
3. Fallbacks are tried in the chain's order (\`GET /meta/providers\`); the first answer that passes every check wins. Per provider 4 s, whole request 9 s, a circuit breaker per provider and chain.

**Safety, on every fallback answer**
- The transaction target and the approval spender must be on Chord's allowlist for that provider and chain, and deployed there.
- \`minAmountOut\` comes from your slippage; a provider minimum below it is refused.
- The value guard of \`/quote\` applies: an output worth 30 % less than the input at Chord's prices is refused. An unpriced token gets a security scan (\`safety\`); a honeypot is refused.
- With \`taker\`, the transaction is simulated as that wallet and must deliver at least \`minAmountOut\`. A fallback transaction that cannot be simulated is never returned.
- Without \`taker\`, a fallback price is shown only after the provider BUILT the route and it was simulated for a placeholder wallet (\`PRICE_CHECKED\`); a provider that prices a size but will not build it is skipped. The placeholder's transaction is never returned.
- An input the simulation cannot supply (a balance that is not a plain storage mapping, e.g. rebasing shares) while the taker does not hold it: HTTP 422 \`INPUT_NOT_SIMULATABLE\` — hold the input and ask again.`;
const metaParams = [
  q("chain", { type: "string" }, "Chain id or key: `143` monad · `4663` robinhood · `5042` arc · `43114` avalanche · `8453` base · `56` bnb.", true),
  q("tokenIn", ADDRESS, "Token you sell. The zero address = the chain's native asset (on Arc it aliases to the USDC predeploy). `inputMint` is accepted too.", true),
  q("tokenOut", ADDRESS, "Token you buy. `outputMint` is accepted too.", true),
  q("amount", WEI, "Input amount, smallest unit.", true),
  q("slippageBps", { type: "integer", minimum: 1, maximum: 5000, default: 50 }, "Sets `minAmountOut`."),
  q("taker", ADDRESS, "The wallet that signs and receives. With it the answer carries `tx`, `approval` and `simulation`. `userPublicKey` is accepted too."),
];
add("/meta/quote", "get", op(T.meta, "metaQuote", "Quote on any chain: Chord first, a fallback only when it fails",
`One call that ends in a route you can sign or an honest "no route anywhere". Without \`taker\` it is a price; with \`taker\` it also returns the unsigned transaction, the approval it needs and a simulation.

${META_POLICY}

**Notes**
- \`provider: null\` with HTTP 200 means every provider looked and none has a route. HTTP 503 \`UNAVAILABLE\` means nobody could answer right now: retry, do not conclude the pair is untradeable.
- The answer is good until \`expiresAt\` (30 s). Quote again before signing if you waited.`,
  {
    params: metaParams,
    responses: withErr({ 200: ok("The quote. Read `provider` and `fallbackReason` before anything else.", ref("MetaQuote"), ex(`/v1/meta/quote?chain=8453&tokenIn=${META_USDC_BASE}&tokenOut=${META_WETH_BASE}&amount=10000000&slippageBps=50&taker=${META_TAKER}`)) }, [400, 422, 429, 503]),
  }));

add("/meta/swap", "post", op(T.meta, "metaSwap", "Unsigned transaction on any chain: Chord first, a fallback only when it fails",
`The same answer as \`/meta/quote\` with a \`taker\` required: an UNSIGNED transaction, simulated as the taker. Chord never signs and never holds funds.

Send the pair and amount, or the \`quoteId\` of a \`/meta/quote\` answer from the last 2 minutes. The policy runs again at the current state, so \`provider\` can differ from the quote's: compare before you sign.

**Before signing**
- \`approval\` not null: send \`token.approve(spender, amount)\` first. \`spender\` is \`tx.to\`.
- When \`provider\` is not \`chord\`, \`tx.to\` is that aggregator's router. Show the user which provider it is.

${META_POLICY}`,
  {
    body: bodyJson(obj({
      chain: { type: "string", description: "Chain id or key." }, tokenIn: ADDRESS, tokenOut: ADDRESS, amount: WEI,
      slippageBps: { type: "integer", minimum: 1, maximum: 5000, default: 50 },
      taker: { ...ADDRESS, description: "The wallet that signs and receives." },
      quoteId: str("Instead of chain / tokens / amount: the id of a `/meta/quote` answer (valid 2 minutes)."),
    }, undefined, { required: ["taker"] }), { chain: 8453, tokenIn: META_USDC_BASE, tokenOut: META_WETH_BASE, amount: "10000000", slippageBps: 50, taker: META_TAKER }),
    responses: {
      ...withErr({ 200: ok("Sign `tx` with any wallet library and submit it to the chain in `tx.chainId`.", ref("MetaQuote"), ex(`/v1/meta/quote?chain=8453&tokenIn=${META_USDC_BASE}&tokenOut=${META_WETH_BASE}&amount=10000000&slippageBps=50&taker=${META_TAKER}`)) }, [400, 422, 429, 503]),
      404: errRes("No provider has a route for this pair and size (`NO_ROUTE`); the body carries `fallbackReason` and `attempts`."),
      410: errRes("Unknown or expired `quoteId` (`QUOTE_EXPIRED`). Send the full params."),
    },
  }));

add("/meta/providers", "get", op(T.meta, "metaProviders", "Fallback order and breaker state per chain",
`Which aggregators stand behind Chord's router on each chain, in the order they are tried, and whether each one's circuit breaker is closed. \`first\` is always \`chord\`.`,
  {
    responses: withErr({ 200: ok("Per chain.", obj({
      policy: str(""),
      chains: arr(obj({ chain: int(""), key: str(""), first: str("Always `chord`."), fallbacks: arr(obj({ provider: str(""), breaker: str("`closed`, `open` (skipped for up to 60 s after 5 infrastructure failures in 2 minutes) or `half-open` (the next request probes it).") })) })),
    }), ex("/v1/meta/providers")) }, [429, 503]),
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

add("/arc/token/{address}/trades", "get", op(T.arc, "arcTokenTrades", "Latest prints", `The last N swaps of one token straight from Chord's own Arc tape (newest first): venue, side, size, USD, price, wallet (\`null\` until resolved) and pool. Bounded and index-served — the mobile token page's Feed tab.`,
  { params: [p("address", ADDRESS, ""), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "Newest rows.")],
    responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 5042 }, token: ADDRESS, trades: arr(obj({ tx: str(""), logIndex: int(""), dex: str(""), side: { type: "string", enum: ["buy", "sell"] }, tokenAmt: num("Whole tokens."), usd: num(""), priceUsd: num(""), ts: UNIX_S, wallet: nullable(ADDRESS), pool: str("Pool address or V4 poolId.") })), updatedAt: UNIX_MS }), ex(`/v1/arc/token/${TOK}/trades?limit=2`)) }, [400, 503]) }));

// Tokens and charts ────────────────────────────────────────────────────────────────────────────
add("/tokens", "get", op(T.tokens, "listTokens", "Curated token list", `Metadata for the tokens Chord routes and labels: address, symbol, name, decimals, logo, tags. On Arc the list leads with the USDC predeploy (the gas token's ERC-20 face) and EURC; on Robinhood Chain with ETH, WETH, USDG and every tokenized stock. Read \`decimals\` here instead of assuming 18.`,
  { params: [chainQ([5042, 4663, 143], { def: 143, required: true })], responses: withErr({ 200: ok("", obj({ tokens: arr(obj({ address: ADDRESS, symbol: str(""), name: str(""), decimals: int(""), logoURI: nullable(str("")), logoUriRaw: nullable(str("")), verified: bool(""), tags: arr({ type: "string" }), liquidityUsd: nullable(num("")) })) }), ex("/v1/tokens?chain=5042")) }, [400]) }));

add("/tokens/market", "get", op(T.tokens, "marketMap", "Price map", `Price, 24-hour change, volume and trade count for every priced token in Chord's index of the chain (thousands of rows, not just the curated list), in one call, keyed by lower-cased address.

- \`4663\` Robinhood Chain: every row also carries a 24-point hourly \`spark\` and \`liquidityUsd\` where known; the answer has \`updatedAt\`, the time the live overlay was applied.
- \`5042\` Arc: from the Arc hourly rollup. \`change24h\` and \`liquidityUsd\` appear only when known; no \`spark\`, no \`updatedAt\`.

For names, logos and honesty flags use \`/arc/tokens\` or \`/rh/tokens\`. Always pass \`chain\`: omitted, it answers for Monad.`,
  { params: [chainQ([4663, 5042], { required: true })], responses: { 200: ok("", obj({ market: obj({}, "address → market row", { additionalProperties: obj({ priceUsd: num(""), change24h: num("Absent when there is no price 24 hours ago."), volume24h: num("Includes trades the hourly rollup has not counted yet (4663)."), txns24h: int(""), liquidityUsd: num("Absent when unknown."), spark: arr({ type: "number" }, "4663 only: 24 hourly closes.") }) }), updatedAt: int("4663 only. Server time (ms) the live overlay was applied; compare with a WebSocket `prices` frame's `at`.") }), { market: { "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec": { priceUsd: 220.97, change24h: -0.71, volume24h: 34504046, txns24h: 103172, spark: [221.4, 221.1, 220.9] } }, updatedAt: 1790708400000 }) } }));

// Hand-built from the live NVDA row of GET /v1/tokens?chain=4663 (raw logo URL, as the search returns it) on 2026-10-03:
// the chain-aware search (routes/tokens.ts, board #97) was not deployed when this was written, so it could not be captured.
// After the next api deploy, capture "/v1/tokens/search?q=NVDA&chain=4663" into examples.json and switch this to ex(...).
const SEARCH_EXAMPLE = { chain: 4663, q: "NVDA", tokens: [{ address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", symbol: "NVDA", name: "NVIDIA • Robinhood Token", decimals: 18, logoURI: "https://cdn.robinhood.com/ncw_assets/logos/0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec.png", verified: true, tags: ["stock"] }] };
add("/tokens/search", "get", op(T.tokens, "searchTokens", "Search tokens on a chain", `Symbol, name or address. What it searches depends on \`chain\`:

- \`4663\` Robinhood Chain: the curated list (\`verified: true\`, stocks tagged \`stock\`) plus tokens that traded in the last 24 hours and are not on it (\`verified: false\`, no logo).
- \`5042\` Arc: every token traded in the last 24 hours, the same index as \`/arc/tokens/search\`. \`verified\` is true for tokens on the curated Arc list.
- \`43114\` / \`8453\` / \`56\`: that chain's token list, all \`verified: true\`. A chain that is not public yet answers \`404 CHAIN_NOT_PUBLIC\` unless the request carries an \`X-API-Key\`.
- no \`chain\`, or \`143\`: Monad off-list discovery. Tokens found through DexScreener that are **not** on the curated Monad list, with a logo and on-chain decimals, all \`verified: false\`. This mode answers \`{ tokens }\` only, returns up to 8 rows whatever \`limit\` says, and returns an empty list for a query under 2 characters.

Ranking: the exact address, then the exact symbol, a symbol prefix, a name prefix, then any substring; verified rows first within a rank, one row per address. A leading \`$\` is ignored. Treat \`verified: false\` as unvetted and check the address before trading it.

**Arc**: \`/arc/tokens/search\` returns full board rows (price, volume, pools, flags) for the same query.`,
  { params: [
      q("q", { type: "string", minLength: 1, maxLength: 64 }, "Symbol, name or address fragment.", true),
      chainQ([4663, 5042, 43114, 8453, 56, 143], { def: 143, note: "Pass the chain you want: the default is Monad off-list discovery." }),
      q("limit", { type: "integer", minimum: 1, maximum: 25, default: 8 }, "Rows to return, clamped to 1–25. Ignored in Monad mode."),
    ],
    responses: {
      200: ok("Matches, best first. An empty `tokens` is a real answer.", obj({
        chain: int("The chain searched. Absent in Monad mode."), q: str("The query as received. Absent in Monad mode."),
        tokens: arr(obj({
          address: ADDRESS, symbol: str(""), name: str(""), decimals: nullable(int("ERC-20 decimals. Null for an off-list token whose decimals are not resolved yet.")),
          logoURI: nullable(str("Logo URL when known. Absent on off-list Robinhood Chain rows.")),
          verified: bool("On the chain's curated list. False = found by the index or by discovery, not vetted."),
          tags: arr({ type: "string" }, "`stock`, `stablecoin`, … from the curated list (Robinhood Chain); `meme` in Monad mode. Absent when empty."),
          liquidityUsd: nullable(num("Monad mode only: liquidity of the deepest DexScreener pair.")),
        }, undefined, { required: ["address", "symbol", "name", "decimals", "verified"] })),
      }, undefined, { required: ["tokens"] }), SEARCH_EXAMPLE),
      400: errRes("`BAD_CHAIN` (a chain this route does not search) or `BAD_QUERY` (`q` empty or longer than 64 characters). Monad mode does not validate `q`."),
      404: errRes("`CHAIN_NOT_PUBLIC`: the chain is not public yet and the request has no `X-API-Key`."),
    } }));

add("/tokens/chart/{address}", "get", op(T.tokens, "tokenChart", "Candles", `OHLCV candles from Chord's own tape, address-keyed — one call serves Arc and Robinhood Chain tokens (addresses cannot collide). 200 candles per page; \`before\` pages backwards for unlimited history. A token that is not on a curated list and not a side of an indexed pool is \`404 UNKNOWN_TOKEN\`. For live candles subscribe on \`/v1/ws/live\` (see Streaming).`,
  { params: [p("address", ADDRESS, ""), q("tf", { type: "string", enum: ["1m", "5m", "15m", "1h", "4h", "1d", "1w"], default: "1h" }, "Timeframe."), q("before", UNIX_S, "Return the 200 candles before this time (paging).")],
    responses: withErr({ 200: ok("", obj({ candles: arr(ref("Candle"), "Oldest first."), tf: str(""), source: str("`db` = Chord's tape.") }), ex(`/v1/tokens/chart/${TOK}?tf=1h`)) }, [400, 404, 503]) }));

add("/candles", "get", op(T.tokens, "candles", "Candles (data API)", `OHLCV for any token Chord indexes on Arc, Robinhood Chain, Avalanche, Base, BNB Chain or Monad, built only from Chord's own index — never a third-party feed, so \`source\` is always \`index\`. 1m / 5m / 15m come from a 1-minute rollup that keeps history after raw trades are retired; 1h and above from the hourly rollup; the newest minutes straight from the tape. Each candle carries \`n\`, the trades in the bucket. Buckets without a trade are absent unless \`fill=1\`, which carries the previous close through them.\n\nPaging: the default window ends with the still-open bucket (\`forming: true\`) and holds \`limit\` buckets. A \`from\`–\`to\` range wider than \`limit\` keeps the newest buckets; ask for the previous page with \`to\` = this page's \`from\`. The token must trade on the chain you name — \`404 UNKNOWN_TOKEN\` says which chain it trades on when it is another one. The zero address stands for the chain's native asset (its wrapped twin, or the USDC predeploy on Arc). For live candles subscribe on \`/v1/ws/live\` (see Streaming).\n\n**Avalanche, Base, BNB Chain** (\`43114\`, \`8453\`, \`56\`): candles come from chain-keyed tables, so one address on two chains is two tokens, and \`404 UNKNOWN_TOKEN\` means no indexed trades on the chain you named. These chains answer once their tape runs and, until the chain is public, only to requests with an \`X-API-Key\` (\`400 UNSUPPORTED_CHAIN\` otherwise; all three are public today). Where the tape runs with an ingest floor (BNB Chain, $100 today) the response carries \`ingestFloor\`, and \`v\` and \`n\` count only trades at or above it.`,
  { params: [chainQ([5042, 4663, 43114, 8453, 56, 143], { def: 143 }), q("token", ADDRESS, "Token address.", true), q("tf", { type: "string", enum: ["1m", "5m", "15m", "1h", "4h", "1d", "1w"], default: "1h" }, "Timeframe."), q("from", UNIX_S, "Start, inclusive. Default: `to` minus `limit` buckets."), q("to", UNIX_S, "End, exclusive, snapped up to a bucket edge. Default: the end of the open bucket."), q("limit", { type: "integer", minimum: 1, maximum: 1000, default: 300 }, "Buckets per page."), q("fill", { type: "string", enum: ["1"] }, "Carry the previous close through empty buckets (v = 0, n = 0).")],
    responses: withErr({ 200: ok("", obj({ chain: int(""), token: ADDRESS, tf: str(""), source: str("Always `index`."), from: UNIX_S, to: UNIX_S, forming: bool("The last candle is the still-open bucket."), ingestFloor: { ...ref("IngestFloor"), description: "Only on 43114 / 8453 / 56 when the tape runs with a floor (BNB Chain)." }, candles: arr(obj({ t: UNIX_S, o: num(""), h: num(""), l: num(""), c: num(""), v: num("USD volume in the bucket."), n: nullable(int("Trades in the bucket.")) }), "Oldest first.") }), ex(`/v1/candles?chain=5042&token=${TOK}&tf=1h&limit=2`)) }, [400, 404, 503]) }));

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
    responses: withErr({ 200: ok("", obj({ tokens: arr(ref("PnlToken")), realized: num(""), unrealized: num(""), total: num(""), exitedWithoutSale: loose("Present when bought quantity left the wallet with no sale on the tape (a transfer out, or a sale credited to another address): `{tokens, costUsd, top: [{symbol, costUsd}]}`. Its result is unknown and NOT in the PnL above."), byChain: loose("Only with `chain=all`."), updatedAt: UNIX_MS }), ex(`/v1/portfolio/${WAL}/pnl?chain=5042`)) }, [400]) }));

// Board #116 (2026-10-04): the Ask Wallet view and the Ask trade card's "pay from / sell from" pickers read this.
const BAL_WAL = "0x0d36a315083033d3d097950c9e494acc04588f99";
add("/wallet/{wallet}/balances", "get", op(T.portfolio, "walletBalances", "Holdings on every chain", `What a wallet holds right now on Chord's six chains (Monad, Robinhood Chain, Arc, Avalanche, Base, BNB Chain), read on-chain: the native coin plus every token on Chord's list for each chain, priced by Chord's own maps. \`raw\` is the exact balance in the token's smallest unit (use it for a Max button); \`amount\` is the same number in whole tokens. Each chain answers on its own deadline: a slow or failing chain comes back \`unavailable\` with a reason and the others still answer. Only listed tokens are seen; a token outside Chord's lists will not show. Cached 15 s per wallet and chain set.`,
  { params: [p("wallet", ADDRESS, ""), q("chains", { type: "string" }, "Comma list of chain ids (143, 4663, 5042, 43114, 8453, 56). Default: all six; unknown ids are ignored.")],
    responses: withErr({ 200: ok("", obj({ wallet: ADDRESS, totalUsd: num("Sum of priced holdings."), updatedAt: UNIX_MS,
      chains: arr(obj({ chain: int(""), name: str(""), status: { type: "string", enum: ["ok", "unavailable", "no_rpc"] }, reason: str("Only when not ok."), totalUsd: num(""),
        holdings: arr(obj({ symbol: str(""), name: nullable(str("")), address: nullable(str("Null for the native coin.")), native: bool(""), decimals: int(""), raw: str("Exact balance, smallest unit."), amount: str("Whole tokens."), priceUsd: nullable(num("")), valueUsd: nullable(num("")), logoURI: nullable(str("")), stable: bool("") }), "Highest value first.") })) }), ex(`/v1/wallet/${BAL_WAL}/balances?chains=8453`)) }, [400]) }));

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

add("/lp/pools/{pool}", "get", op(T.lp, "lpPool", "One pool", `The pool row plus its hourly series (the last 168 hours by default; \`hours\` up to 720), the top providers over 7 days, the health score with its parts and reasons, launch facts (who launched it, how much of the liquidity the launcher holds and has pulled), and \`mint\` — what a wallet needs to add liquidity here (the position manager, the pool key, Permit2, tick spacing).`,
  { params: [p("pool", POOL_ID, ""), LP_CHAIN, q("hours", int(""), "Hours of the hourly series, 24 to 720 (default 168)")], responses: withErr({ 200: ok("", { allOf: [ref("PoolListRow"), obj({ chain: int(""), hourly: arr(obj({ hour: int(""), vol: num(""), trades: int(""), price: nullable(num("")) })), topLps: arr(obj({ wallet: ADDRESS, addUsd: num(""), removeUsd: num(""), netUsd: num(""), events: int(""), lastTs: UNIX_S })), health: obj({ score: int(""), parts: obj({ traders: num(""), tvl: num(""), yieldSanity: num(""), lpFlow: num(""), age: num(""), penalties: num("") }), reasons: arr({ type: "string" }) }), launch: nullable(obj({ launcher: nullable(ADDRESS), launcherName: nullable(str("")), creator: nullable(ADDRESS), hooks: nullable(ADDRESS), launchedTs: nullable(UNIX_S), launcherLpAddedUsd: num(""), totalLpAddedUsd: num(""), launcherSharePct: nullable(num("")), launcherLastRemoveTs: nullable(UNIX_S), launcherRemovedUsd: num("") })), mint: nullable(obj({ kind: str(""), manager: nullable(ADDRESS), permit2: ADDRESS, token0: ADDRESS, token1: ADDRESS, feePips: nullable(int("")), tickSpacing: nullable(int("")), hooks: ADDRESS, feeRaw: nullable(int("V4 dynamic-fee pools carry the 0x800000 flag.")), nativeCurrency0: bool("") })), updatedAt: UNIX_MS })] }, ex(`/v1/lp/pools/${POOL}?chain=5042`)) }, [400, 404]) }));

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
add("/ask/status", "get", op(T.ask, "askStatus", "Is the analyst on", "Whether Ask is enabled, whether guest sessions are open, and today's token budget.", { responses: { 200: ok("", obj({ enabled: bool(""), chain: { type: "integer", const: 5042 }, guest: bool(""), privy: bool("The server accepts Privy sign-in (the Ask wallet)"), budget: obj({ used: int(""), total: int("") }) }), ex("/v1/ask/status")) } }));
add("/ask", "post", op(T.ask, "ask", "Ask the analyst",
`Chord's analyst over the Arc index and the router — 40+ tools (trending, a token's flow, holders and risk, support and resistance with an entry ladder, top traders on a token, a wallet's PnL and trades, largest prints, launches, depth, a bridge quote, position sizing, read-only SQL over the index). Returns the answer, source links, an optional route card, tables and charts the analysis produced, and a report when one was built.

**Auth**: a developer API key (\`X-API-Key\`) or a Google session bearer. Metered per key per day against the deployment's token budget; 8 questions a minute per caller.

**Agents**: send \`"stream": false\` for one JSON answer (5–40 s). Without it the response is \`text/event-stream\` with \`status\` events (which tool is running), one \`answer\` event, then \`done\`.`,
  { security: [{ ApiKey: [] }, { Session: [] }],
    body: bodyJson(obj({ question: { type: "string", maxLength: 1000, description: "May be empty when `images` is set." }, stream: { type: "boolean", description: "false = one JSON response instead of SSE." }, history: arr(obj({ role: { type: "string", enum: ["user", "assistant"] }, content: { type: "string", maxLength: 4000 }, images: arr({ type: "string" }, "Image ids that user turn carried — their reading comes back as context.") }), "Up to 12 prior turns."), wallet: { ...ADDRESS, description: "The caller's wallet, so \"my PnL\" resolves." }, images: arr({ type: "string", pattern: "^[a-f0-9]{32}$" }, "Up to 4 ids from `POST /v1/ask/image` (your own, 30 days). The analyst reads each image — chart, positions, a swap or wallet screenshot — before it answers, and can zoom into one.") }, undefined, { required: ["question"] }), { question: "What is moving on Arc right now, and is ARGUS still being bought by real wallets?", stream: false }),
    responses: withErr({ 200: ok("With `stream: false`: the whole answer. Otherwise `text/event-stream`.", obj({ text: str("The answer, Markdown."), citations: arr(loose("Source links (endpoint + parameters the answer read).")), quote: nullable(loose("A route card when the question implied a trade.")), artifact: nullable(loose("Chart levels, ladder, zones, report link.")), walletArtifact: nullable(loose("")), viz: arr(loose("Tables and charts (`kind`: table · bar · line · donut).")), toolsUsed: arr({ type: "string" }), tokens: int("Model tokens spent.") })) }, [400, 401, 429, 503]) }));
add("/ask/picks", "get", op(T.ask, "askPicks", "Ask Picks board", "The analyst's current picks (rebuilt every four hours over tokens with real activity): side, score, confidence, target and invalidation with how each was set, the reasons for and against, and the facts behind them — plus the seven-day track record.", { responses: { 200: ok("", obj({ chain: { type: "integer", const: 5042 }, computedAt: nullable(UNIX_S), picks: arr(obj({ ts: UNIX_S, token: ADDRESS, symbol: nullable(str("")), side: { type: "string", enum: ["bullish", "bearish"] }, score: num(""), confidence: { type: "string", enum: ["low", "medium", "high"] }, priceUsd: num(""), target: num(""), invalidation: num(""), levels: obj({ target: num(""), targetFrom: str(""), invalidation: num(""), invalidationFrom: str("") }), why: arr({ type: "string" }), against: arr({ type: "string" }), facts: loose("") })), trackRecord7d: nullable(obj({ graded: int(""), targetHits: int(""), stopHits: int(""), expired: int(""), open: int(""), avgMovePct: num(""), hitRatePct: num("") })) }), ex("/v1/ask/picks")) } }));
add("/ask/report", "post", op(T.ask, "askReport", "Build a research note", "Builds Chord's three-page research note for a token (HTML → PDF in the browser, plus Markdown) and returns links good for seven days.", { security: [{ Session: [] }], body: bodyJson(obj({ token: str("Address or symbol on Arc."), summary: { type: "string", maxLength: 4000, description: "Optional analyst text to place on the first page." } }, undefined, { required: ["token"] }), { token: "ARGUS" }), responses: withErr({ 200: ok("", obj({ id: str(""), url: str("HTML."), mdUrl: str("Markdown.") })) }, [400, 401, 404, 429, 503]) }));
add("/ask/image", "post", op(T.ask, "askImageUpload", "Attach an image", "Uploads one image for a question (PNG, JPEG, WebP, GIF first frame; ≤ 12 MB). It is re-encoded as a JPEG no wider or taller than 2048 px, with its metadata (EXIF, GPS) removed, and kept 30 days. Send the returned `id` in `images` of `POST /v1/ask`. 30 uploads per 10 minutes per caller.", { security: [{ ApiKey: [] }, { Session: [] }], body: { required: true, content: { "multipart/form-data": { schema: obj({ file: { type: "string", format: "binary" } }, undefined, { required: ["file"] }) }, "image/*": { schema: { type: "string", format: "binary" } } } }, responses: withErr({ 200: ok("", obj({ id: str("32 hex characters."), url: str("`/v1/ask/image/{id}`."), width: int(""), height: int(""), bytes: int("") })) }, [400, 401, 429, 503]) }));
add("/ask/image/{id}", "get", op(T.ask, "askImage", "Fetch an attached image", "The stored JPEG. Public by unguessable id (an `<img>` sends no bearer), 30 days.", { params: [p("id", { type: "string" }, "Image id.")], responses: { 200: { description: "`image/jpeg`.", content: { "image/jpeg": { schema: { type: "string", format: "binary" } } } }, 404: ERR[404] } }));
add("/ask/report/{id}", "get", op(T.ask, "askReportGet", "Fetch a report", "The note as HTML, or Markdown with a `.md` suffix. Public by unguessable id, seven days.", { params: [p("id", { type: "string" }, "Report id, optionally with `.md`.")], responses: { 200: { description: "`text/html` or `text/markdown`.", content: { "text/html": { schema: { type: "string" } }, "text/markdown": { schema: { type: "string" } } } }, 404: ERR[404] } }));
add("/ask/export/{id}", "get", op(T.ask, "askExport", "Fetch a CSV export", "A table the analyst exported, as CSV (one hour).", { params: [p("id", { type: "string" }, "Export id, optionally with `.csv`.")], responses: { 200: { description: "`text/csv`.", content: { "text/csv": { schema: { type: "string" } } } }, 404: ERR[404] } }));

// Bridge ───────────────────────────────────────────────────────────────────────────────────────
add("/bridge2/config", "get", op(T.bridge, "bridge2Config", "CCTP chain table", `Circle CCTP V2 fast transfer to and from Arc: the chains and domains, USDC addresses, the TokenMessenger / MessageTransmitter contracts, and the Arc-side relayer (address, balance, enabled). The browser signs the burn; Chord proxies the attestation and relays the Arc mint.`,
  { responses: { 200: ok("", obj({ provider: { type: "string", const: "cctp-v2" }, fastFinalityThreshold: int(""), arcDomain: int(""), contracts: obj({ tokenMessengerV2: ADDRESS, messageTransmitterV2: ADDRESS }), chains: arr(obj({ chainId: int(""), domain: int(""), name: str(""), usdc: ADDRESS })), relayer: obj({ address: nullable(ADDRESS), arcBalance: nullable(str("Wei.")), enabled: bool("") }) }), ex("/v1/bridge2/config")) } }));
add("/bridge2/fee", "get", op(T.bridge, "bridge2Fee", "CCTP fee", "Circle's minimum fee for a fast and a standard transfer between two domains, in basis points.", { params: [q("src", { type: "integer" }, "Source CCTP domain.", true), q("dst", { type: "integer" }, "Destination CCTP domain.", true)], responses: withErr({ 200: ok("", obj({ src: int(""), dst: int(""), fastBps: num(""), standardBps: num("") })) }, [400, 503]) }));
add("/bridge2/status", "get", op(T.bridge, "bridge2Status", "Attestation status", "Iris status for a burn transaction: `not_found`, `pending` or `complete` with the message and attestation when ready.", { params: [q("srcDomain", { type: "integer" }, "", true), q("tx", TX_HASH, "The burn transaction.", true)], responses: withErr({ 200: ok("", obj({ status: { type: "string", enum: ["not_found", "pending", "complete"] }, srcDomain: int(""), tx: TX_HASH, message: nullable(str("")), attestation: nullable(str("")), eventNonce: nullable(str("")), decoded: nullable(loose("")) })) }, [400, 503]) }));
add("/bridge2/relay", "post", op(T.bridge, "bridge2Relay", "Relay the Arc mint", "Once attested, Chord's relayer submits `receiveMessage` on Arc so the recipient needs no gas there. `409 NOT_ATTESTED` until Iris completes; `429 DAILY_CAP`; `503 RELAYER_OFF`.", { body: bodyJson(obj({ srcDomain: int(""), tx: TX_HASH }, undefined, { required: ["srcDomain", "tx"] }), { srcDomain: 6, tx: "0x…" }), responses: withErr({ 200: ok("", obj({ ok: { type: "boolean", const: true }, txHash: TX_HASH })), 409: errRes("`NOT_ATTESTED` or `IN_FLIGHT`.") }, [400, 429, 502, 503]) }));

const PROVIDER_Q = q("provider", { type: "string", enum: ["lifi", "relay"] }, "Bridge provider. Chord uses `lifi`.");

// Swap V2 — cross-chain composed swap (docs/swap-v2-crosschain.md). Chains 143 · 4663 · 5042.
const XSWAP_BODY = obj({ user: ADDRESS, chainIn: { type: "integer", enum: [143, 4663, 5042] }, chainOut: { type: "integer", enum: [143, 4663, 5042] }, tokenIn: ADDRESS, tokenOut: ADDRESS, amount: WEI, slippageBps: { type: "integer", minimum: 10, maximum: 500, default: 100 }, recipient: ADDRESS, rail: { type: "string", enum: ["auto", "relay", "cctp"], default: "auto", description: "Force a rail; `auto` applies the corridor rules (Robinhood → Relay; Monad ↔ Arc → CCTP when the mint relayer is funded; else Relay)." } }, undefined, { required: ["user", "chainIn", "chainOut", "tokenIn", "tokenOut", "amount"] });
const XSWAP_EXAMPLE = { user: WAL, chainIn: 5042, chainOut: 143, tokenIn: USDC, tokenOut: "0x350035555e10d9afaf1566aaebfced5ba6c27777", amount: "1000000000", slippageBps: 100 };
const SWAP_LEG = obj({ kind: { type: "string", const: "swap" }, chainId: int(""), tokenIn: ADDRESS, tokenOut: ADDRESS, amountIn: WEI, amountOut: WEI, priceImpactPct: num(""), feeBps: int("Our tier fee on this leg's output."), dexIds: arr({ type: "string" }) });
const BRIDGE_LEG = obj({ kind: { type: "string", const: "bridge" }, rail: { type: "string", enum: ["relay", "cctp"] }, chainIdIn: int(""), chainIdOut: int(""), tokenIn: ADDRESS, tokenOut: ADDRESS, amountIn: WEI, amountOut: WEI, timeEstimateSec: num(""), requestId: str("Relay intent id; empty on CCTP until the burn is sent."), srcDomain: int("CCTP only."), dstDomain: int("CCTP only."), feeBps: num("Circle's fast-transfer fee, CCTP only.") });
const XSWAP_FEES = obj({ protocol: obj({ originBps: int(""), destBps: int(""), usd: num("") }, "Our on-chain tier fee per swap leg."), bridge: obj({ rail: str(""), usd: num(""), bps: num(""), appFeeBps: int("App fee added on Relay.") }, "The bridge's own cut."), network: obj({ usd: num("Flat per relayer-paid transaction."), covered: bool("true = we eat it (Arc mint)."), mode: { type: "string", enum: ["user", "usdc-gas", "gasless", "solver", "none"] } }, "Gas we front on the destination."), totalUsd: num("") });
const XSWAP_QUOTE = obj({ chainIn: int(""), chainOut: int(""), tokenIn: ADDRESS, tokenOut: ADDRESS, amountIn: WEI, amountOut: WEI, legs: arr({ oneOf: [SWAP_LEG, BRIDGE_LEG] }), timeEstimateSec: num(""), rail: { type: "string", enum: ["relay", "cctp"] }, railReason: str("Why this rail."), fees: XSWAP_FEES, gas: obj({ origin: str(""), dest: str("") }, "Who pays gas on each side."), minAnchorUnits: WEI, bridge: loose("Rail-shaped: `{ rail, requestId, checkEndpoint, steps[], fees, details }` — sign `steps` in order on the origin chain (an `approval` item may be skipped when the allowance covers it).") });
add("/xswap/plan", "post", op(T.bridge, "xswapPlan", "Cross-chain swap plan", "Quotes a token on one chain into a token on another two ways at once — **composed** (Chord's router on the origin → USDC/USDG rail → Chord's router on the destination) and **direct** (Relay end to end) — and names the one that lands more. Long-tail tokens on Arc / Monad / Robinhood only route on the composed path. Fees come back as three lines (protocol · bridge · network) and `gas` says who pays on each side. `MIN_SIZE` below 10 USD of the bridged stable.", { body: bodyJson(XSWAP_BODY, XSWAP_EXAMPLE), responses: withErr({ 200: ok("", obj({ best: { type: "string", enum: ["composed", "direct"] }, composed: nullable(XSWAP_QUOTE), direct: nullable(XSWAP_QUOTE), errors: loose("Per-path failure `{ code, message }` when a path could not be quoted.") })) }, [400, 404, 429, 502, 503]) }));
add("/xswap/quote", "post", op(T.bridge, "xswapQuote", "Composed cross-chain quote", "The composed path only (see `/xswap/plan`).", { body: bodyJson(XSWAP_BODY, XSWAP_EXAMPLE), responses: withErr({ 200: ok("", XSWAP_QUOTE) }, [400, 404, 429, 502, 503]) }));
add("/xswap/order", "post", op(T.bridge, "xswapOrder", "Register a cross-chain order", "Quotes and records the order the wallet is about to sign so it can be resumed after a refresh: the server tracks the bridge (Relay status or Circle attestation), mints CCTP transfers on Arc, and re-quotes the final leg at the amount that actually arrived. Poll `GET /xswap/order?id=`. `path: \"direct\"` registers the Relay end-to-end candidate instead.", { body: bodyJson(obj({ ...XSWAP_BODY.properties, path: { type: "string", enum: ["composed", "direct"], default: "composed" } }, undefined, { required: XSWAP_BODY.required }), XSWAP_EXAMPLE), responses: withErr({ 200: ok("", obj({ order: loose("`{ id, state, rail, chainIn, chainOut, tokenIn, tokenOut, amountIn, quotedOut, requestId, originTxHash?, destTxHash?, bridgedAmount?, destQuote?, claim?, note? }` — states: pending_origin · bridging · pending_dest · done · stuck_dest · failed_origin."), quote: XSWAP_QUOTE, requoteToleranceBps: int("") })) }, [400, 404, 429, 502, 503]) }));
add("/xswap/order", "get", op(T.bridge, "xswapOrderGet", "Advance and read an order", "Asks the bridge where the money is and, once it landed, returns a fresh destination-leg quote (`destQuote`) to sign. Polling this is what moves the order.", { params: [q("id", { type: "string", pattern: "^[a-f0-9]{32}$" }, "Order id.", true)], responses: withErr({ 200: ok("", obj({ order: loose(""), requoteToleranceBps: int("") })) }, [400, 404, 502]) }));
add("/xswap/orders", "get", op(T.bridge, "xswapOrders", "A wallet's in-flight orders", "Newest first — how a client recovers cross-chain state it never held locally.", { params: [q("user", ADDRESS, "", true)], responses: withErr({ 200: ok("", obj({ orders: arr(loose("")) })) }, [400, 502]) }));
add("/relayers", "get", op(T.account, "relayers", "Relayer gas health", "For each chain Chord's relayer pays gas on (Monad gasless swaps, Robinhood Permit2 swaps, Arc CCTP mints): its address, native balance, current gas price and the estimated transactions that balance still covers. `ok` = above the floor; the cross-chain planner stops routing through a relayer that is not ok.", { params: [q("force", { type: "string", enum: ["1"] }, "Re-read now instead of the 60 s cache.")], responses: { 200: ok("", obj({ minTx: int("The floor."), relayers: arr(obj({ chainId: int(""), name: str(""), symbol: str(""), role: str(""), configured: bool(""), address: nullable(ADDRESS), balance: nullable(WEI), gasPrice: nullable(WEI), gasPerTx: int(""), txRemaining: nullable(int("")), ok: bool(""), checkedAt: UNIX_MS, error: str("") })), updatedAt: UNIX_MS })) } }));
add("/crosschain/config", "get", op(T.bridge, "crosschainConfig", "Bridge providers and chains", "Whether the provider is enabled, its app fee, the origin chains this deployment offers, and the destination chains with display names, native symbols, explorers and icons.", { params: [PROVIDER_Q, q("origin", { type: "integer" }, "Exclude this chain from the list.")], responses: { 200: ok("", obj({ enabled: bool(""), provider: str(""), appFeeBps: num(""), origins: arr({ type: "integer" }), origin: nullable(int("")), chains: arr(obj({ id: int(""), name: str(""), displayName: str(""), nativeSymbol: str(""), explorerUrl: str(""), featured: bool(""), iconUrl: nullable(str("")) })) }), ex("/v1/crosschain/config?provider=lifi")) } }));
add("/crosschain/currencies", "get", op(T.bridge, "crosschainCurrencies", "Bridgeable tokens on a chain", "Tokens the provider can move on a chain, filtered by a search term.", { params: [q("chainId", { type: "integer" }, "", true), q("q", { type: "string", maxLength: 40 }, "Symbol or name (≥ 2 characters)."), PROVIDER_Q], responses: withErr({ 200: ok("", obj({ chainId: int(""), provider: str(""), currencies: arr(loose("Token rows (address, symbol, name, decimals, logo).")) })) }, [400, 503]) }));
add("/crosschain/quote", "post", op(T.bridge, "crosschainQuote", "Bridge quote", "A cross-chain quote from the provider: the steps, fees and the transactions to sign on the origin chain (an approve step is added when the origin token is an ERC-20). Poll `/crosschain/status` with the deposit hash.", { body: bodyJson(obj({ user: ADDRESS, originChainId: { type: "integer", default: 143 }, destinationChainId: int(""), originCurrency: ADDRESS, destinationCurrency: ADDRESS, amount: WEI, slippageBps: { type: "integer", minimum: 10, maximum: 500, default: 100 }, recipient: ADDRESS, provider: { type: "string", enum: ["lifi", "relay"] }, usePermit: bool("Relay only: a permit (signature) deposit instead of a transaction, for tokens that support it (native USDC on Arbitrum).") }, undefined, { required: ["user", "destinationChainId", "originCurrency", "destinationCurrency", "amount"] }), { user: WAL, originChainId: 8453, destinationChainId: 5042, originCurrency: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", destinationCurrency: USDC, amount: "100000000", slippageBps: 100, provider: "lifi" }), responses: withErr({ 200: ok("", loose("`{ provider, requestId, steps[], fees, details, checkEndpoint, txns[] }` — provider-shaped; sign `txns` in order.")) }, [400, 429, 502, 503]) }));
add("/crosschain/permit", "post", op(T.bridge, "crosschainPermit", "Submit a signed permit deposit", "Hands a signed `signature` step from a `usePermit` quote back to the provider (Relay only): send the step's `post.body` fields plus the EIP-712 signature. Then poll `/crosschain/status`.", { body: bodyJson(obj({ requestId: { type: "string", pattern: "^0x[a-fA-F0-9]{64}$" }, kind: str("e.g. `eip3009`"), api: str("e.g. `swap`"), signature: str("0x… EIP-712 signature") }, undefined, { required: ["requestId", "kind", "api", "signature"] }), { requestId: "0x17900816413eb4c1d4ec4b00d0be87c6b60872ed43d103eb87dc22a0b80ff325", kind: "eip3009", api: "swap", signature: "0x…" }), responses: withErr({ 200: ok("", loose("Provider-shaped acknowledgement.")) }, [400, 429, 502, 503]) }));
add("/crosschain/status", "get", op(T.bridge, "crosschainStatus", "Bridge status", "Status of a bridge by its request id or deposit hash: `waiting` · `depositing` · `pending` · `submitted` · `success` · `delayed` · `refund` · `failure` · `unknown`.", { params: [q("requestId", { type: "string", pattern: "^0x[a-fA-F0-9]{64}$" }, "Request id (or the deposit tx hash on LI.FI).", true), PROVIDER_Q, q("fromChain", { type: "integer" }, ""), q("toChain", { type: "integer" }, "")], responses: withErr({ 200: ok("", obj({ status: { type: "string", enum: ["waiting", "depositing", "pending", "submitted", "success", "delayed", "refund", "failure", "unknown"] }, substatus: str(""), inTxHashes: arr({ type: "string" }), txHashes: arr({ type: "string" }), explorerLink: str(""), updatedAt: UNIX_MS })) }, [400, 429, 502, 503]) }));

// Robinhood Chain data ─────────────────────────────────────────────────────────────────────────
const RH_INTRO = "Chain 4663 only; takes no `chain` parameter. Served from Chord's rollup tables, never from a raw scan. `503 NOT_READY` until the rollup has run.";
add("/rh/status", "get", op(T.rh, "rhStatus", "Rollup freshness", RH_INTRO, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, enabled: bool(""), recentAt: nullable(UNIX_S), staleSec: nullable(int("")), floorHour: nullable(int("")), genesisHour: nullable(int("")), backfillComplete: bool(""), updatedAt: UNIX_MS }), ex("/v1/rh/status")) }, [503]) }));
add("/rh/overview", "get", op(T.rh, "rhOverview", "Chain totals", `Last 24 hours, venue share, 24 hourly buckets and up to 30 daily rows. ${RH_INTRO}`, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, last24h: obj({ volUsd: num(""), swaps: int(""), tokens: int(""), sinceHour: int("") }), venues24h: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), tokens: int(""), sharePct: num("") })), hourly24: arr(obj({ hour: int(""), volUsd: num(""), swaps: int("") })), daily: arr(obj({ day: int(""), swaps: int(""), volUsd: num(""), tokens: int(""), wallets: int(""), venues: int("") })), coverage: ref("Coverage"), updatedAt: UNIX_MS }), ex("/v1/rh/overview")) }, [503]) }));
add("/rh/venues", "get", op(T.rh, "rhVenues", "Venue share over a window", RH_INTRO, { params: [q("days", { type: "integer", minimum: 1, maximum: 180, default: 30 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, days: int(""), venues: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num(""), series: arr(obj({ day: int(""), volUsd: num(""), trades: int(""), tokens: int("") })) })), totals: obj({ volUsd: num(""), trades: int("") }) })) }, [400, 503]) }));
add("/rh/tokens", "get", op(T.rh, "rhTokens", "Every token traded in the last 24 hours", `Price, change, volume split, trade counts and attributed traders. Unlisted tokens (no curated metadata or logo) are hidden unless asked for. ${RH_INTRO}`, { params: [q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, ""), q("sort", { type: "string", enum: ["volume", "trades", "traders", "change"], default: "volume" }, ""), q("includeUnlisted", { type: "integer", enum: [0, 1], default: 0 }, "")], responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, sinceHour: int(""), tradersSince: int(""), sort: str(""), tokens: arr(ref("RhTokenRow")), total: int(""), updatedAt: UNIX_MS }), ex("/v1/rh/tokens?limit=2")) }, [400, 503]) }));
add("/rh/token/{address}", "get", op(T.rh, "rhToken", "One token: hourly tape and venue split", RH_INTRO, { params: [p("address", ADDRESS, ""), q("hours", { type: "integer", minimum: 1, maximum: 720, default: 168 }, "")], responses: withErr({ 200: ok("", obj({ token: obj({ address: ADDRESS, symbol: nullable(str("")) }), series: arr(obj({ hour: int(""), volUsd: num(""), buyUsd: num(""), sellUsd: num(""), trades: int(""), buys: int(""), sells: int(""), priceLast: nullable(num("")) })), byDex: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num("") })) })) }, [400, 503]) }));
add("/rh/stocks", "get", op(T.rh, "rhStocks", "Tokenized stocks", `Every tokenized stock and ETF on chain 4663 with its 24-hour tape, NAV basis where the issuer publishes a rate, and the share of the last seven days that traded outside the NYSE session. ${RH_INTRO}`, { responses: withErr({ 200: ok("", obj({ chain: { type: "integer", const: 4663 }, sinceHour: int(""), tradersSince: int(""), stocks: arr(ref("RhStockRow")), note: str(""), updatedAt: UNIX_MS }), ex("/v1/rh/stocks")) }, [503]) }));

// Avalanche, Base, BNB Chain ───────────────────────────────────────────────────────────────────
// routes/chains.ts + services/chainRollup.ts + services/chainWallet.ts. Examples captured live on BNB Chain (the chain with an ingest floor).
const CH_TOK = "0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c"; // BTCB on BNB Chain
const CH_WAL = "0x34135a8b5cc02d1b579789fb09dd9cec4f8d7c13";
const CHAINS_INTRO = `Chain-keyed data for Avalanche C-Chain, Base and BNB Chain, served from Chord's rollup tables for the chain (every swap summed by hour, token and venue). Only the trade tape, the prints ticker and the wallet read raw rows, scoped to one token or one wallet and bounded.

- **Access.** No key needed while the chain is public (all three are today). A chain whose tape is off, or that is not public yet, answers \`400 UNSUPPORTED_CHAIN\` ("chain N is not served yet") unless the request carries an \`X-API-Key\`; those answers are sent \`Cache-Control: private\`.
- **Ingest floor.** Every count, volume and print covers trades at or above the chain's floor, returned as \`ingestFloor\`. BNB Chain runs at $100 today; Avalanche and Base at 0.
- **Readiness.** \`503 NOT_READY\` until the chain's rollup has run on this deployment; \`503 CHAIN_DATA_UNAVAILABLE\` when the store cannot be read. Never treat either as "no trades".`;
const CHAIN_P = p("chain", { type: "string", enum: ["avalanche", "base", "bnb", "43114", "8453", "56"] }, "The chain, by key or id: `avalanche` or `43114`, `base` or `8453`, `bnb` or `56` (case-insensitive). Arc, Robinhood Chain and Monad are refused with `400 UNSUPPORTED_CHAIN` and a pointer to their own routes.");
const CH_ADDR_P = p("address", ADDRESS, "Token address. The zero address means the chain's wrapped native token (WAVAX, WETH, WBNB).");
const CH_503 = errRes("`NOT_READY` (the chain's rollup has not run on this deployment yet) or `CHAIN_DATA_UNAVAILABLE` (the store could not be read). Retry later; do not treat it as an empty answer.");
const CH_503_STORE = errRes("`CHAIN_DATA_UNAVAILABLE`: the store could not be read. Retry later; do not treat it as an empty answer.");
const chErr = (responses, bad400, extra = {}, s503 = CH_503) => ({ ...responses, 400: errRes(`\`UNSUPPORTED_CHAIN\` (unknown chain, a chain with its own routes, or a chain not served to this caller yet)${bad400 ? `, or ${bad400}` : ""}.`), ...extra, 429: ERR[429], 503: s503 });

add("/chains/{chain}/status", "get", op(T.chains, "chainStatus", "Rollup freshness and coverage", `Is the chain's rollup fresh, how far back it reaches, whether the tape and the public flag are on, where the raw tape is cut, and the ingest floor. Answers 200 even before the first rollup pass (\`recentAt\` is then null). Check it before trusting a quiet number.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P], responses: chErr({ 200: ok("", obj({
    chain: int("Registry id."), enabled: bool("The rollup and the tape both run."), tape: bool("The chain's trade tape runs."), public: bool("Served to callers without a key."),
    recentAt: nullable(UNIX_S), staleSec: nullable(int("Seconds since the last rollup pass.")), floorHour: nullable(int("Oldest hour the backfill has rolled.")),
    genesisHour: nullable(int("The chain's first indexed hour, when this server knows it; often null.")), backfillComplete: bool("True once the backfill has reached the first indexed hour."),
    retentionCutoffDay: nullable(int("UTC day start. Raw trades before it are retired from the database (about 3 days on BNB Chain and Base, 7 on Avalanche today); the hourly and daily rollups keep their history.")),
    ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS,
  }), ex("/v1/chains/bnb/status")) }, "", {}, CH_503_STORE) }));

add("/chains/{chain}/overview", "get", op(T.chains, "chainOverview", "Chain totals", `Last 24 hours (volume, swaps, tokens, venues), distinct wallets per UTC day, venue share, 24 hourly buckets and up to 14 daily rows.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P], responses: chErr({ 200: ok("", obj({
    chain: int(""), last24h: obj({ volUsd: num(""), swaps: int(""), tokens: int(""), venues: int(""), sinceHour: int("Start of the window.") }),
    wallets: obj({ day: UNIX_S, today: nullable(int("Distinct attributed wallets so far today (UTC); partial.")), yesterday: nullable(int("")) }, "Calendar-day counts, never a sliding 24 hours. Null = no day row yet."),
    venues24h: arr(ref("ChainVenueShare"), "Biggest first."), hourly24: arr(obj({ hour: int(""), volUsd: num(""), swaps: int("") }), "Oldest first."),
    daily: arr(obj({ day: int(""), swaps: int(""), volUsd: num(""), tokens: int(""), wallets: int("Attributed wallets only."), venues: int("") }), "Up to 14 days, oldest first. The first day of a young tape is partial."),
    coverage: ref("ChainCoverage"), ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS,
  }), ex("/v1/chains/bnb/overview")) }, "") }));

add("/chains/{chain}/tokens", "get", op(T.chains, "chainTokens", "Every token traded in the last 24 hours", `The chain's 24-hour board: price on the busiest venue, change, volume split, trade counts and the dominant venue for every token that traded, with symbol, name and decimals read from the contract. There is no curated list on these chains yet: rows carry no logo, no \`listed\` flag, no trader count and no wash or impostor flags, so check the address before trusting a symbol.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, ""), q("sort", { type: "string", enum: ["volume", "trades", "change"], default: "volume" }, "Descending.")],
    responses: chErr({ 200: ok("", obj({ chain: int(""), sinceHour: int(""), sort: str(""), total: int("Tokens that traded in the window."), tokens: arr(ref("ChainTokenRow")), coverage: ref("ChainCoverage"), ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS }), ex("/v1/chains/bnb/tokens?limit=2")) }, "`BAD_LIMIT` / `BAD_SORT`") }));

add("/chains/{chain}/prints", "get", op(T.chains, "chainPrints", "Latest prints across the chain", `The newest swaps of tokens on the chain's 24-hour board, newest first: a ticker, not a tape. It looks back ten minutes, skips trades under $1, keeps at most three prints a token so one busy pair does not fill it, and is shared for 10 seconds per chain. For one token's full tape use \`/chains/{chain}/token/{address}/trades\`.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, q("limit", { type: "integer", minimum: 1, maximum: 50, default: 20 }, "")],
    responses: chErr({ 200: ok("", obj({ chain: int(""), prints: arr(obj({ tx: TX_HASH, logIndex: int(""), block: int(""), dex: str(""), token: ADDRESS, side: { type: "string", enum: ["buy", "sell"] }, usd: num(""), priceUsd: num(""), ts: UNIX_S, symbol: str("From the board.") })), updatedAt: UNIX_MS }), ex("/v1/chains/bnb/prints?limit=2")) }, "`BAD_LIMIT`") }));

add("/chains/{chain}/token/{address}", "get", op(T.chains, "chainToken", "One token: hourly tape and venue split", `The token's identity (read from the contract), 24-hour stats, an hourly series (1–720 hours) and the venue split for the window. \`404 UNKNOWN_TOKEN\` when the chain's rollups have never seen the token trade; the same address on another chain is another token. For a price of a token Chord has not seen trade, \`/ref-price\` asks CoinGecko.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, CH_ADDR_P, q("hours", { type: "integer", minimum: 1, maximum: 720, default: 168 }, "Hourly buckets to return.")],
    responses: chErr({ 200: ok("", obj({
      chain: int(""), token: obj({ address: ADDRESS, symbol: nullable(str("")), name: nullable(str("")), decimals: nullable(int("")), logoURI: { type: "null" } }), hours: int(""),
      stats24h: obj({ volUsd: num(""), buyUsd: num(""), sellUsd: num(""), trades: int(""), buys: int(""), sells: int(""), lastTs: UNIX_S, dominantDex: nullable(str("")), priceUsd: nullable(num("Last print on the dominant venue.")), priceThen: nullable(num("Price 24 hours ago, same rule.")), change24hPct: nullable(num("")), sinceHour: int("") }),
      series: arr(obj({ hour: int(""), volUsd: num(""), buyUsd: num(""), sellUsd: num(""), trades: int(""), buys: int(""), sells: int(""), priceLast: nullable(num("The busiest venue's last print in the hour.")) }), "Oldest first. Hours without a trade are absent."),
      byDex: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num("") }), "Over the requested window, biggest first."),
      coverage: ref("ChainCoverage"), ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS,
    }), ex(`/v1/chains/bnb/token/${CH_TOK}?hours=2`)) }, "`BAD_ADDRESS` / `BAD_HOURS`", { 404: errRes("`UNKNOWN_TOKEN`: no indexed trades for this token on this chain.") }) }));

add("/chains/{chain}/token/{address}/ref-price", "get", op(T.chains, "chainTokenRefPrice", "Reference price from CoinGecko", `CoinGecko's price and 24-hour change for a token by contract address, for a token Chord's index has not seen trade (or to cross-check one it has). Not Chord's own data: the answer says so in \`source\`. Cached two minutes; \`ageS\` is the age of the cached CoinGecko answer.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, CH_ADDR_P],
    responses: chErr({ 200: ok("", obj({ chain: int(""), address: ADDRESS, priceUsd: num(""), change24hPct: nullable(num("")), source: { type: "string", const: "coingecko" }, ageS: int("Seconds since CoinGecko answered.") }), ex(`/v1/chains/bnb/token/${CH_TOK}/ref-price`)) }, "`BAD_ADDRESS`", { 404: errRes("`NOT_LISTED`: CoinGecko does not list this token on this chain.") }, errRes("`UNAVAILABLE`: CoinGecko did not answer. Retry later.")) }));

add("/chains/{chain}/token/{address}/trades", "get", op(T.chains, "chainTokenTrades", "Trade tape", `The token's swaps straight from the raw tape, newest first: venue, side, size, USD, price, block, wallet (\`null\` for a router or an unattributed trade, never a guess) and pool. Keyset-paged: pass \`nextBefore\` back as \`before\` for the next page; \`nextBefore\` is null on the last one. The raw tape is short on these chains (see \`retentionCutoffDay\` on \`/status\`), so paging stops there.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, CH_ADDR_P, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "Newest rows."), q("before", { type: "string", pattern: "^\\d{1,12}(:\\d{1,15}:\\d{1,9})?$" }, "Exclusive cursor: the previous page's `nextBefore` (`ts:block:logIndex`), or a Unix second.")],
    responses: chErr({ 200: ok("", obj({ chain: int(""), token: ADDRESS, trades: arr(obj({ tx: TX_HASH, logIndex: int(""), block: int(""), dex: str(""), side: { type: "string", enum: ["buy", "sell"] }, tokenAmt: num("Whole tokens."), usd: num(""), priceUsd: num(""), ts: UNIX_S, wallet: nullable(ADDRESS), pool: POOL_ID })), nextBefore: nullable(str("Cursor for the next page; null when this page is not full.")), ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS }), ex(`/v1/chains/bnb/token/${CH_TOK}/trades?limit=2`)) }, "`BAD_ADDRESS` / `BAD_LIMIT` / `BAD_BEFORE`") }));

add("/chains/{chain}/venues", "get", op(T.chains, "chainVenues", "Venue share over a window", `Per-venue volume, trades and share for 1–30 UTC days, with a daily series per venue. The first day of a young tape is partial.\n\n${CHAINS_INTRO}`,
  { params: [CHAIN_P, q("days", { type: "integer", minimum: 1, maximum: 30, default: 30 }, "Window length, in UTC days including today.")],
    responses: chErr({ 200: ok("", obj({ chain: int(""), days: int(""), since: UNIX_S, venues: arr(obj({ dex: str(""), volUsd: num(""), trades: int(""), sharePct: num(""), series: arr(obj({ day: int(""), volUsd: num(""), trades: int(""), tokens: int("") })) }), "Biggest first."), totals: obj({ volUsd: num(""), trades: int("") }), updatedAt: UNIX_MS }), ex("/v1/chains/bnb/venues?days=2")) }, "`BAD_DAYS`") }));

add("/chains/{chain}/wallet/{address}", "get", op(T.chains, "chainWallet", "One wallet's swaps and PnL", `A wallet's swaps on the chain and an average-cost PnL over them. **The window is short**: the database keeps the raw tape for a few days on these chains (about 3 on BNB Chain and Base, 7 on Avalanche today), and older days come from Chord's data lake only where its days run without a gap up to that window. \`window\` says how far back the numbers go and \`history\` where they came from (\`raw\`, \`raw+lake\`, or \`raw (lake unavailable)\`). Say so when you show the number.

- A buy adds tokens and cost; a sell realizes proceeds minus the average cost of the part the window saw bought.
- A sell with nothing bought in the window has no cost basis: it is counted in \`soldWithoutBasisUsd\`, never as profit.
- \`holdsTokens\` is bought minus sold inside the window, priced at the token's last hourly print. It is not the on-chain balance (transfers are not swaps).
- Trades under the chain's ingest floor are not in the tape (BNB Chain: $100).
- Past 5,000 swaps in the window the newest 5,000 are kept and \`truncated\` is true (a bot or a router).

${CHAINS_INTRO}`,
  { params: [CHAIN_P, p("address", ADDRESS, "Wallet address.")],
    responses: chErr({ 200: ok("", obj({
      chain: int(""), wallet: ADDRESS,
      window: obj({ fromTs: nullable(UNIX_S), toTs: UNIX_S, days: nullable(int("")) }, "The span the numbers cover. `fromTs` null = no trades indexed for the wallet."),
      history: { type: "string", enum: ["raw", "raw+lake", "raw (lake unavailable)"], description: "Where the window's rows came from." },
      trades: int("Swaps in the window."), truncated: bool("More than 5,000 swaps in the window: only the newest 5,000 are counted."),
      realizedUsd: num(""), unrealizedUsd: num(""), totalUsd: num(""), volumeUsd: num(""), soldWithoutBasisUsd: num("Sell proceeds with no buy in the window to match. Not profit."),
      tokens: arr(obj({ token: ADDRESS, symbol: nullable(str("")), buys: int(""), sells: int(""), boughtUsd: num(""), soldUsd: num(""), realizedUsd: num(""), unrealizedUsd: num(""), totalUsd: num(""), holdsTokens: num("Bought minus sold in the window, whole tokens."), holdsUsd: num(""), avgCostUsd: nullable(num("Average cost per token of what is still held.")), lastPriceUsd: nullable(num("Last hourly print within 7 days.")), soldWithoutBasisUsd: num("") }), "Largest absolute PnL first."),
      recent: arr(obj({ ts: UNIX_S, tx: TX_HASH, logIndex: int(""), token: ADDRESS, side: { type: "string", enum: ["buy", "sell"] }, tokenAmt: num(""), usd: num(""), priceUsd: num(""), dex: str(""), symbol: nullable(str("")) }), "Last 25 swaps, newest first."),
      ingestFloor: ref("IngestFloor"), updatedAt: UNIX_MS,
    }), ex(`/v1/chains/bnb/wallet/${CH_WAL}`)) }, "`BAD_ADDRESS`", {}, CH_503_STORE) }));

// Solana data ──────────────────────────────────────────────────────────────────────────────────
// routes/solana.ts (validation) → services/solTape.ts (one HTTP call to the Solana box) → packages/sol/src/queries.ts (shapes,
// mirrored fail-open in schemas/sol.ts). Not in CHAIN_REGISTRY: base58 addresses, case-sensitive — never lower-case one here.
// Examples captured live on 2026-10-05 (Agency, a pump.fun graduate on PumpSwap; a small manual wallet that traded it).
const SOL_TOK = "7VertkgF9KLhxxJXHX6uaWuoYZTP9LdGj2bWmVXVpump";
const SOL_WAL = "3QZv9xcDELwLqB8SggDJHfVhMTn5YhKtXMCaKUucutm3";
// Captured at 02:17 UTC while the ingest was ~4 h behind the chain: the UTC day had no rows yet, so the board was empty (and a
// cold days=2 board outlasted the API's 20 s). Re-capture a filled board when the tape is current.
const SOL_BOARD_KEY = "/v1/chains/solana/traders?limit=2";
const SOL_SMART_KEY = "/v1/chains/solana/smart-traders?days=7&limit=2";
const SOL_ADDR = { type: "string", pattern: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", description: "Solana address, base58, case-sensitive. Never lower-case it." };
const SOL_SIG = { type: "string", pattern: "^[1-9A-HJ-NP-Za-km-z]{64,88}$", description: "Transaction signature, base58." };
const SOL_TS = int("Unix time, seconds, UTC.");
const SOL_UPDATED = int("Unix time, SECONDS, when the Solana box built this answer. Unlike the rest of the API (milliseconds).");
const SOL_DEX = str("Venue id: `pumpswap` · `pumpfun` (bonding curve) · `meteora_dbc` · `meteora_damm_v2` · `meteora_dlmm` · `meteora_pools` (dynamic AMM v1) · `raydium_clmm` · `raydium_cpmm` · `raydium_v4` · `raydium_launchlab` · `orca` (Whirlpool).");
const SOL_INTRO = `Chord's own Solana tape, read-only. No key needed.

- **What it reads.** The swap events of 11 venues: PumpSwap, the pump.fun bonding curve, Meteora DBC, Meteora DAMM v2, Meteora DLMM, Meteora pools (dynamic AMM v1), Raydium CLMM, Raydium CPMM, Raydium AMM v4, Raydium LaunchLab and Orca Whirlpool. Each swap is checked against the pool vaults' balance changes in the same transaction.
- **What it does not read.** Prop AMMs (SolFi, HumidiFi and the like) and order books. SOL/USDC and other major pairs therefore show far less volume than the whole market; the numbers are accurate for pump.fun, Meteora and Raydium style tokens. Transfers are not seen either: wallet PnL is average cost inside the window.
- **History.** Live since 2026-10-03 12:01 UTC, plus a backfill of the days before. \`coverageSince\` on \`/chains/solana/overview\` says from when totals are complete: quote that field, not a date.
- **Addresses** are base58 and **case-sensitive**. Never lower-case a mint or a wallet: a lower-cased mint is a different string, refused with \`400 BAD_ADDRESS\` when it stops being base58 (an \`L\` becomes \`l\`) and answered \`404 TOKEN_NOT_FOUND\` otherwise. Solana has no numeric chain id here: the path segment is the literal \`solana\`.
- **Units.** Token amounts are whole tokens (decimals already applied), \`quoteAmount\` is whole units of the pool's quote (SOL, USDC, USDT or the other token), prices and \`*Usd\` fields are US dollars. Timestamps, \`updatedAt\` included, are Unix **seconds**.
- **Names are untrusted.** \`symbol\`, \`name\` and \`image\` are whatever the token's creator wrote; many mints share a symbol and there are no wash or impostor flags. Identify a token by its mint.
- **Errors.** \`400 BAD_*\` for a bad parameter; \`400 UNSUPPORTED_CHAIN\` if Solana is not public on the deployment and the request has no \`X-API-Key\`; \`503 CHAIN_DATA_UNAVAILABLE\` when the Solana store cannot be read in time and \`503 CHAIN_NOT_ENABLED\` when the lane is off: retry later, never read either as "no trades".`;
const SOL_ERR = (bad400, extra = {}) => ({
  400: errRes(`${bad400 ? `${bad400}, or ` : ""}\`UNSUPPORTED_CHAIN\` (Solana is not public on this deployment and the request has no \`X-API-Key\`).`),
  ...extra,
  429: ERR[429],
  503: errRes("`CHAIN_DATA_UNAVAILABLE` (the Solana store did not answer in time) or `CHAIN_NOT_ENABLED` (the lane is off on this deployment). Retry later; do not treat it as an empty answer."),
});
const SOL_MINT_P = p("address", SOL_ADDR, "Token mint, base58, exactly as it appears on-chain.");
const SOL_WAL_P = p("address", SOL_ADDR, "Wallet address, base58, exactly as it appears on-chain.");
const SOL_404 = { 404: errRes("`TOKEN_NOT_FOUND`: this mint has not traded on a venue the tape reads since the tape started.") };
const SOL_BEFORE = q("before", { type: "integer", minimum: 0, maximum: 4000000000 }, "Exclusive cursor, Unix seconds: rows strictly older than it. Pass the last row's `ts` for the next page. Several swaps can share a second, so a page boundary can skip the rest of that second: overlap with `ts + 1` and drop rows whose `tx` you already have.");

const SolTokenRow = obj({
  token: SOL_ADDR, symbol: nullable(str("Creator-chosen; null until the metadata worker has read it.")), name: nullable(str("Creator-chosen.")), image: nullable(str("Image URL from the token's metadata, as published by its creator.")),
  decimals: nullable(int("")), priceUsd: nullable(num("Last price on the token's main pool (traded in the last hour first, then the deepest).")),
  change24hPct: nullable(num("Price now against the main pool's close 24 hours ago.")),
  volume24hUsd: num("USD over the 24-hour window, every pool the tape reads."), trades24h: int(""), buys24h: int(""), buyVolume24hUsd: num(""),
  liquidityUsd: nullable(num("Main pool: twice its quote-side reserve in USD, from the last swap whose event carried the reserve. An estimate; null when unknown.")),
  marketCapUsd: nullable(num("Price × supply: fully diluted.")), pool: nullable(SOL_ADDR), dex: nullable(SOL_DEX), firstSeen: nullable(SOL_TS),
}, "One Solana token with its 24-hour tape.");
const SolPosition = obj({
  token: SOL_ADDR, symbol: nullable(str("")), name: nullable(str("")), image: nullable(str("")), priceUsd: nullable(num("Current price on the main pool.")),
  boughtUsd: num(""), soldUsd: num(""), boughtAmount: num("Whole tokens."), soldAmount: num("Whole tokens."), buys: int(""), sells: int(""),
  heldAmount: num("Bought minus sold inside the window, whole tokens (never below 0). Not the on-chain balance."), heldValueUsd: nullable(num("")),
  realizedPnlUsd: nullable(num("Matched amount × (average sell − average buy). Null when the window has sells but no buys.")), unrealizedPnlUsd: nullable(num("Held amount × (price − average buy).")),
  partial: bool("Sold more than it bought inside the window: part of the position was bought before the window (or arrived by transfer), so those sells carry no cost basis."),
  lastDay: SOL_TS,
}, "One token in a wallet's window.");
components.schemas.SolTokenRow = SolTokenRow;
components.schemas.SolPosition = SolPosition;

add("/chains/solana/status", "get", op(T.sol, "solStatus", "Is the tape following the chain", `The ingest's own health: the last slot written, how far behind the chain it is, the age of the newest block it has written, swaps per minute, and per-venue decode counters since the ingest started (\`decode\` is keyed by venue number: 1 pumpswap · 2 pumpfun · 3 meteora_dbc · 4 meteora_damm_v2 · 5 meteora_dlmm · 6 raydium_clmm · 7 orca · 8 raydium_cpmm · 9 raydium_v4 · 10 meteora_pools · 11 raydium_launchlab; the example shows two of the eleven). \`ok: false\` or a large \`blockAgeS\` means the numbers on the other routes are behind: say so when you show them. Never cached.\n\n${SOL_INTRO}`,
  { responses: { 200: ok("", obj({
    chain: { type: "string", const: "solana" }, ok: bool("The ingest is healthy right now."), cursor: int("Last slot written."), genesisSlot: int("First slot of the live tape."), auditCursor: int("Last slot re-checked against `finalized` (orphaned slots removed, late ones written)."),
    lagSlots: nullable(int("Slots between the chain head and `cursor`.")), blockAgeS: nullable(int("Age of the newest block written, seconds.")), slotsPerMin: nullable(num("")), swapsPerMin: nullable(num("")),
    startedAt: nullable(SOL_TS), solUsd: nullable(num("SOL price the tape is using (from its own SOL/stable swaps).")),
    decode: obj({}, "Venue number → counters since `startedAt`.", { additionalProperties: obj({ events: int(""), swaps: int(""), ok: int("Swaps whose amounts match the vaults' balance changes exactly."), bad: int("Swaps that do not match."), unchecked: int("Not checkable (a fee paid to a third account, a pool created and seeded in the same transaction)."), noParent: int(""), otherEvents: int("") }) }),
    totals: nullable(obj({ slots: int(""), swaps: int(""), orphaned: int(""), late: int("") }, "Since `startedAt`.")),
    venues: str("What the tape reads, in words."), notCovered: str("What it does not read, in words."), public: bool("Served to callers without a key."),
    gate: nullable(loose("The automatic public gate: `pass`, `liveHours`, `missing24h` (missing slots in 24 hours), `hourCheck` (rollup against raw for the last closed hour), `reasons`.")),
  }), ex("/v1/chains/solana/status")), ...SOL_ERR("") } }));

add("/chains/solana/overview", "get", op(T.sol, "solOverview", "Chain totals", `Last 24 hours on the venues the tape reads: volume, trades, buys, tokens traded, venue share and hourly buckets, plus \`coverageSince\`. The window never starts before \`coverageSince\`: \`coverageHours\` under 24 means a partial day. Cached 30 seconds.\n\n${SOL_INTRO}`,
  { responses: { 200: ok("", obj({
    chain: { type: "string", const: "solana" }, windowHours: int(""), volumeUsd: num(""), trades: int(""), buys: int(""), tokensTraded: int(""),
    venues: arr(obj({ dex: SOL_DEX, volumeUsd: num(""), trades: int(""), share: num("Fraction of the window's volume, 0–1 (not percent).") }), "Biggest first."),
    hourly: arr(obj({ hour: SOL_TS, volumeUsd: num(""), trades: int("") }), "Oldest first; `hour` is the bucket start."),
    coverageSince: nullable(SOL_TS), coverageHours: num("Hours of the 24-hour window the tape covers."), cursor: int("Last slot written."), updatedAt: SOL_UPDATED,
  }), ex("/v1/chains/solana/overview")), ...SOL_ERR("") } }));

add("/chains/solana/tokens", "get", op(T.sol, "solTokens", "Every token traded in the last 24 hours", `The 24-hour board. \`volume\` and \`trades\` rank every token the tape saw; \`change\` (24-hour price change) and \`new\` (first seen in the last 24 hours, newest first) rank inside the 400 most traded tokens with at least $5,000 of volume, so a $40 pool moving 900 % is not a mover. Cached 20 seconds.\n\nNo wash flags here: a thin pool can print a large volume (compare \`volume24hUsd\` with \`liquidityUsd\` and \`trades24h\` before ranking on it), and many tokens share a symbol.\n\n${SOL_INTRO}`,
  { params: [q("sort", { type: "string", enum: ["volume", "trades", "change", "new"], default: "volume" }, "Descending; `new` = newest first."), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, "")],
    responses: { 200: ok("", obj({ sort: str(""), windowHours: int(""), tokens: arr(ref("SolTokenRow")), updatedAt: SOL_UPDATED }), ex("/v1/chains/solana/tokens?sort=trades&limit=2")), ...SOL_ERR("`BAD_LIMIT` / `BAD_SORT`") } }));

add("/chains/solana/search", "get", op(T.sol, "solSearch", "Find a token by mint, symbol or name", `A mint returns that token (when the tape has seen it trade). Anything else is an exact, case-insensitive match on symbol or name among the tokens the tape has seen, up to 20, ordered by the volume of each token's deepest pool; a leading \`$\` is ignored. No prefix or substring search. Expect several mints per symbol: show the mint, and pick by liquidity and volume only when the user has not named one.\n\n\`volumeUsd\` is the main pool's volume since the tape first saw it for a symbol or name match, and the token's 24-hour volume for a mint: a ranking hint, not a window total. Use \`/chains/solana/token/{address}\` for the token's numbers.\n\n${SOL_INTRO}`,
  { params: [q("q", { type: "string", minLength: 1, maxLength: 60 }, "A mint (base58), a symbol or a name.", true)],
    responses: { 200: ok("Matches. An empty `tokens` is a real answer.", obj({ chain: { type: "string", const: "solana" }, query: str(""), tokens: arr(obj({ token: SOL_ADDR, symbol: nullable(str("")), name: nullable(str("")), image: nullable(str("")), priceUsd: nullable(num("")), liquidityUsd: nullable(num("")), volumeUsd: nullable(num("See above.")) })) }), ex("/v1/chains/solana/search?q=Agency")), ...SOL_ERR("`BAD_QUERY` (empty, or longer than 60 characters)") } }));

add("/chains/solana/token/{address}", "get", op(T.sol, "solToken", "One token: stats, pools and hourly tape", `Identity (from the token's metadata), price on the main pool with 1-hour and 24-hour change, fully diluted market cap, liquidity summed over the pools that traded in the last 24 hours, 24-hour volume and trade counts with the venue split, up to 20 pools, and an hourly series.\n\n**Pass \`hours\` of 24 or more**: the 24-hour totals are summed from the same hourly rows the series returns, so \`hours=2\` gives the totals of two hours. In \`pools\`, \`volumeUsd\` and \`swaps\` count since the tape first saw the pool, not 24 hours. Cached 10 seconds.\n\n${SOL_INTRO}`,
  { params: [SOL_MINT_P, q("hours", { type: "integer", minimum: 1, maximum: 720, default: 168 }, "Hourly buckets in `hourly`; also the span the 24-hour totals are read from (see above).")],
    responses: { 200: ok("", obj({
      chain: { type: "string", const: "solana" }, token: SOL_ADDR, symbol: nullable(str("")), name: nullable(str("")), image: nullable(str("")), decimals: nullable(int("")), supply: nullable(num("Whole tokens.")), firstSeen: nullable(SOL_TS),
      priceUsd: nullable(num("")), change1hPct: nullable(num("")), change24hPct: nullable(num("")), marketCapUsd: nullable(num("Price × supply.")), liquidityUsd: nullable(num("Sum over pools that traded in the last 24 hours.")),
      volume24hUsd: num(""), trades24h: int(""), buys24h: int(""), sells24h: int(""), buyVolume24hUsd: num(""), sellVolume24hUsd: num(""),
      venues: arr(obj({ dex: SOL_DEX, volumeUsd: num(""), trades: int("") }), "24-hour venue split, biggest first."),
      pools: arr(obj({ pool: SOL_ADDR, dex: SOL_DEX, quote: SOL_ADDR, priceUsd: nullable(num("")), liquidityUsd: nullable(num("")), volumeUsd: num("Since the tape first saw the pool."), swaps: int("Since the tape first saw the pool."), firstSeen: nullable(SOL_TS), lastTrade: nullable(SOL_TS) }), "Up to 20; traded in the last hour first, then the deepest."),
      hourly: arr(obj({ hour: SOL_TS, volumeUsd: num(""), trades: int(""), buys: int("") }), "Oldest first. Hours without a trade are absent."),
      updatedAt: SOL_UPDATED,
    }), ex(`/v1/chains/solana/token/${SOL_TOK}?hours=24`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_HOURS`", SOL_404) } }));

add("/chains/solana/token/{address}/trades", "get", op(T.sol, "solTokenTrades", "Trade tape", `The token's newest swaps across up to 30 of its pools, newest first: side, both amounts, USD, price, venue, pool, wallet and the transaction signature. Each page looks back at most two days from \`before\` (or from now): an empty page means no swap in that span. A mint the tape has never seen answers an empty list.\n\n- \`side\`: \`buy\` = the wallet bought the token, \`sell\` = it sold it.\n- \`tokenAmount\` and \`quoteAmount\` are what the wallet received or paid, fees included, in whole units; \`priceUsd\` is the pool's execution price.\n- \`wallet\` is the user account named in the swap instruction: often a bot or an arbitrage contract, sometimes on both sides of one transaction.\n\n${SOL_INTRO}`,
  { params: [SOL_MINT_P, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "Newest rows."), SOL_BEFORE],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, token: SOL_ADDR, trades: arr(obj({ ts: SOL_TS, slot: int(""), side: { type: "string", enum: ["buy", "sell"] }, tokenAmount: num("Whole tokens."), quoteAmount: num("Whole units of the pool's quote."), usd: nullable(num("")), priceUsd: nullable(num("")), dex: SOL_DEX, pool: nullable(SOL_ADDR), wallet: nullable(SOL_ADDR), tx: SOL_SIG })), updatedAt: SOL_UPDATED }), ex(`/v1/chains/solana/token/${SOL_TOK}/trades?limit=2`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_LIMIT` / `BAD_CURSOR`") } }));

add("/chains/solana/token/{address}/candles", "get", op(T.sol, "solTokenCandles", "Candles", `OHLCV of ONE pool of the token, in USD: the main pool (traded in the last hour first, then the deepest) unless \`pool\` names another. Not a volume-weighted blend of every pool: use \`/chains/solana/token/{address}\` for totals across pools. The window holds \`limit\` buckets ending with the open one; buckets without a trade are absent. A swap under $1 adds to the volume but does not move the open, high, low or close. Cached 5 seconds for \`1m\`, 20 seconds otherwise.\n\n${SOL_INTRO}`,
  { params: [SOL_MINT_P, q("tf", { type: "string", enum: ["1m", "5m", "15m", "1h", "4h", "1d"], default: "5m" }, "Timeframe."), q("limit", { type: "integer", minimum: 1, maximum: 1000, default: 200 }, "Buckets in the window."), q("pool", SOL_ADDR, "A pool of this token (from `/chains/solana/token/{address}` `pools`). Default: the main pool.")],
    responses: { 200: ok("`pool: null` with no candles = the tape has no priced pool for this mint.", obj({ chain: { type: "string", const: "solana" }, token: SOL_ADDR, pool: nullable(SOL_ADDR), timeframe: str(""), candles: arr(obj({ t: SOL_TS, o: num(""), h: num(""), l: num(""), c: num(""), volumeUsd: num(""), trades: int("") }), "Oldest first; `t` is the bucket start."), updatedAt: SOL_UPDATED }), ex(`/v1/chains/solana/token/${SOL_TOK}/candles?tf=1h&limit=8`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_TIMEFRAME` / `BAD_LIMIT`") } }));

add("/chains/solana/token/{address}/traders", "get", op(T.sol, "solTokenTraders", "Who traded the token", `The wallets that traded the token over the window, biggest USD volume first (the top 100; \`limit\` slices them): bought, sold, net, trades, and an average-cost PnL over the window. The window is whole UTC hours: the current hour and the \`hours\` (1–48) before it, starting at \`since\`, so it covers a little more than \`hours\` × 3600 seconds. Closed hours come from an hourly (token, wallet) rollup and the current hour from the raw swaps; while the rollup has not reached back to \`since\` the whole window is read from raw, and the first read of a busy token can then take tens of seconds or answer \`503\`. The answer is cached on the Solana side: retry after a minute, or ask for fewer \`hours\`.\n\n- \`heldAmount\` is bought minus sold inside the window, not the wallet's balance.\n- \`partial: true\` = the wallet sold more than it bought in the window; those sells have no cost basis.\n\n${SOL_INTRO}`,
  { params: [SOL_MINT_P, q("limit", { type: "integer", minimum: 1, maximum: 100, default: 30 }, ""), q("hours", { type: "integer", minimum: 1, maximum: 48, default: 24 }, "Whole UTC hours before the current one (see `since`).")],
    responses: { 200: ok("", obj({
      chain: { type: "string", const: "solana" }, token: SOL_ADDR, windowHours: int(""), since: SOL_TS, priceUsd: nullable(num("")),
      traders: arr(obj({ wallet: nullable(SOL_ADDR), boughtUsd: num(""), soldUsd: num(""), netUsd: num("Bought minus sold, USD."), trades: int(""), lastTrade: SOL_TS, heldAmount: num("Whole tokens."), heldValueUsd: nullable(num("")), realizedPnlUsd: nullable(num("")), unrealizedPnlUsd: nullable(num("")), partial: bool("") })),
      updatedAt: SOL_UPDATED,
    }), ex(`/v1/chains/solana/token/${SOL_TOK}/traders?limit=2`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_LIMIT` / `BAD_HOURS`", SOL_404) } }));

add("/chains/solana/traders", "get", op(T.sol, "solTraders", "The day's traders", `Wallets ranked by realized PnL or by volume over today's UTC day (\`days=2\` adds yesterday), across every token the tape reads. Bots are left out by rule (\`botRule\`: above 3,000 trades or 300 tokens a day), and so are wallets under $1,000 of volume. Realized PnL per token = the matched amount × (average sell − average buy) inside the window, summed; \`winRate\` = the share of tokens with both buys and sells that sold above their average buy. Early in the UTC day the board is short, and empty until the day has rows. Cached 5 minutes; a cold \`days=2\` board can take longer than the API waits and answer \`503\`: retry later.\n\n${SOL_INTRO}`,
  { params: [q("sort", { type: "string", enum: ["pnl", "volume"], default: "pnl" }, "Descending."), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, ""), q("days", { type: "integer", minimum: 1, maximum: 2, default: 1 }, "1 = today (UTC), 2 = today and yesterday.")],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, sort: str(""), windowDays: int(""), botRule: str("The rule that removed bots, in words."), traders: arr(obj({ wallet: nullable(SOL_ADDR), realizedPnlUsd: num(""), volumeUsd: num(""), trades: int(""), tokens: int("Tokens traded."), winRate: nullable(num("0–1.")) })), updatedAt: SOL_UPDATED }), ex(SOL_BOARD_KEY)), ...SOL_ERR("`BAD_LIMIT` / `BAD_DAYS` / `BAD_SORT`") } }));

add("/chains/solana/smart-traders", "get", op(T.sol, "solSmartTraders", "Smart traders", `The wallets that made repeated, verifiable profit over the last 1, 3 or 7 UTC days (today included): bots, launch wallets and lucky one-offs removed by named rules, then ranked by a luck-corrected \`score\`. Rebuilt every 10 minutes on the Solana side (\`computedAt\`); the request never computes, so it answers in milliseconds, and \`503\` for a few minutes after a deploy until the first build.

How a wallet gets on the board:

- **Profit you can stand behind.** Realized PnL at average cost over the whole window (a position bought on day 1 and sold on day 3 counts), from swaps in pools quoted in SOL, USDC or USDT only. A position with more than 10 % of its amount traded through pools quoted in another token is left out (\`unpricedTokens\`), and so is one returning over 1,000× its cost or selling more than the token's deepest pool could pay (\`suspectTokens\`).
- **A person, not a machine.** Removed by name (\`checked.flags\`): \`cadence\` (over 500 swaps on a day), \`sniper\` (over 150 tokens on a day), \`burst\` (8+ transactions inside a minute, in more minutes than the wallet has active days), \`sameslot\` (sells within 2 s of buying, 5+ and 5 %+ of its sells), \`arb\` (transactions that buy and sell one token), \`scalp\` (median hold under 60 s: gone before anyone could follow), \`launch\` (most closed positions first bought within 2 s of that pool's first swap: creator and bundle wallets).
- **One operator, one row.** Wallets that made their first buy of the same 3+ tokens within 2 s of each other are one operator: the best score stays and carries \`siblings\`; a follower 30 s behind is not grouped.
- **Not luck.** At least 5 tokens bought and sold, 10 swaps, $2,000 of volume, $1,000 realized and a 30 % win rate.
- **Score** = realized × (0.35 + 0.65 × win rate shrunk toward 50 % with 20 phantom positions) × (0.5 + 0.5 × profitable days / active days) × (0.5 when one token made over 80 % of the profit, 0.75 over 60 %) × exp(−hours since the last trade / 48). \`rules\` repeats every threshold in words.

Candidates are the top 250 wallets by realized PnL in the window, so \`sort=roi\` and \`sort=winrate\` reorder that verified set rather than search every wallet; \`roi\` only ranks wallets that put at least $1,000 to work. \`from\` is where the window really starts: never before \`coverageSince\`. Unrealized PnL (\`unrealizedPnlUsd\`, held amount marked at most at the deepest pool's liquidity) is shown, not ranked. Past profit over a few days is not a forecast.\n\n${SOL_INTRO}`,
  { params: [q("days", { type: "integer", enum: [1, 3, 7], default: 7 }, "Window in UTC days, today included."), q("sort", { type: "string", enum: ["score", "pnl", "roi", "winrate"], default: "score" }, "Descending."), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, "")],
    responses: { 200: ok("", obj({
      chain: { type: "string", const: "solana" }, windowDays: int("1, 3 or 7."), sort: str(""), from: SOL_TS, coverageSince: nullable(SOL_TS), computedAt: SOL_TS, tookMs: int("How long the last build of this window took on the Solana side."),
      population: obj({ profitable: int("Wallets over the floors with realized PnL in the window."), cadence: int("Of those, removed for over 500 swaps on a day."), sniper: int("Removed for over 150 tokens on a day.") }),
      checked: obj({ candidates: int("Wallets read swap by swap."), kept: int("On the board."), flags: obj({}, "Candidates removed per rule: cadence, sniper, burst, sameslot, arb, scalp, launch. A wallet can carry several; `launch` is only looked up for wallets no other rule removed.", { additionalProperties: int("") }), suspect: int("Removed because most of the profit came from left-out positions."), ineligible: int("Under a floor once read exactly."), readErrors: int("Candidates whose swaps could not be read this cycle (back next cycle)."), clustered: int("Wallets dropped as a second wallet of an operator already on the board (see `siblings`).") }),
      rules: obj({}, "Every threshold, in words.", { additionalProperties: str("") }),
      traders: arr(obj({
        wallet: SOL_ADDR, score: num("Luck-corrected, recency-weighted realized profit; the default order."), realizedPnlUsd: num(""), roi: nullable(num("Realized ÷ cost of the sold amount; 0.5 = +50 %.")),
        winRate: nullable(num("Share of closed tokens sold above their average buy, 0–1.")), winRateAdj: num("Win rate shrunk toward 0.5."), closedTokens: int("Tokens bought and sold in the window."), winningTokens: int(""), tokens: int(""), trades: int(""), volumeUsd: num(""),
        activeDays: int(""), profitableDays: int("Days whose closed positions (by last sell) netted a profit."), medianHoldS: nullable(num("Median seconds between average buy and average sell, closed tokens.")),
        unrealizedPnlUsd: num("Held amount at the current price (capped at the deepest pool's liquidity) minus its average cost. Not ranked."), heldValueUsd: num(""), costSoldUsd: num("Cost of the sold amount at the average buy."),
        bestToken: nullable(obj({ token: SOL_ADDR, symbol: nullable(str("Creator-chosen.")), name: nullable(str("Creator-chosen.")), image: nullable(str("")), realizedPnlUsd: num("") })), bestShare: nullable(num("The best token's share of realized PnL.")),
        unpricedTokens: int(""), suspectTokens: int(""), launchTokens: int("Closed tokens first bought within 2 s of the pool's first swap."),
        siblings: int("Other wallets of the same operator left off the board: they made their first buy of the same 3+ tokens within 2 s of this one."), lastTrade: SOL_TS,
      })),
    }), ex(SOL_SMART_KEY)), ...SOL_ERR("`BAD_DAYS` / `BAD_SORT` / `BAD_LIMIT`") } }));

add("/chains/solana/wallet/{address}", "get", op(T.sol, "solWallet", "One wallet's tokens and PnL", `What a wallet bought and sold per token over the last \`days\` UTC days (today included), with an average-cost PnL: realized on the sold part, unrealized on what is still held at the current price. Up to 200 tokens, biggest first. Say how far back the numbers go when you show them.\n\n- Transfers are not seen: a token that arrived by transfer and was then sold counts as a sell without a buy. Such rows carry \`partial: true\` (counted in \`partialTokens\`) and their sells have no realized PnL.\n- \`heldAmount\` and \`heldValueUsd\` are bought minus sold inside the window, not the on-chain balance.\n- \`likelyBot\` = more than 3,000 trades or 300 tokens a day.\n\n${SOL_INTRO}`,
  { params: [SOL_WAL_P, q("days", { type: "integer", minimum: 1, maximum: 45, default: 7 }, "Window in UTC days, today included.")],
    responses: { 200: ok("A wallet the tape has never seen answers zeros and an empty `positions`.", obj({
      chain: { type: "string", const: "solana" }, wallet: SOL_ADDR, windowDays: int(""), tokens: int(""), trades: int(""), volumeUsd: num(""), boughtUsd: num(""), soldUsd: num(""),
      realizedPnlUsd: num(""), unrealizedPnlUsd: num(""), heldValueUsd: num(""), winRate: nullable(num("Share of tokens with sells that closed in profit, 0–1.")), partialTokens: int("Tokens with `partial: true`."), likelyBot: bool(""),
      positions: arr(ref("SolPosition"), "Biggest bought + sold first."), updatedAt: SOL_UPDATED,
    }), ex(`/v1/chains/solana/wallet/${SOL_WAL}?days=7`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_DAYS`") } }));

add("/chains/solana/wallet/{address}/trades", "get", op(T.sol, "solWalletTrades", "A wallet's swaps", `The wallet's newest swaps on the venues the tape reads, newest first, with the token and its symbol. Each page looks back at most seven days from \`before\` (or from now).\n\n${SOL_INTRO}`,
  { params: [SOL_WAL_P, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "Newest rows."), SOL_BEFORE],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, wallet: SOL_ADDR, trades: arr(obj({ ts: SOL_TS, slot: int(""), side: { type: "string", enum: ["buy", "sell"] }, token: SOL_ADDR, symbol: nullable(str("")), name: nullable(str("")), tokenAmount: num("Whole tokens."), quoteAmount: num("Whole units of the pool's quote."), usd: nullable(num("")), priceUsd: nullable(num("")), dex: SOL_DEX, pool: nullable(SOL_ADDR), tx: SOL_SIG })), updatedAt: SOL_UPDATED }), ex(`/v1/chains/solana/wallet/${SOL_WAL}/trades?limit=2`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_LIMIT` / `BAD_CURSOR`") } }));

// Solana liquidity (LP) ─────────────────────────────────────────────────────────────────────────
// routes/solana.ts → services/solTape.ts → packages/sol/src/lpQueries.ts. Examples captured live on 2026-10-06: the SOL/USDC
// Meteora DLMM pool below and an LP wallet with closed positions in it.
const SOL_LP_POOL = "HTvjzsfX3yU6BUodCjZ5vZkUrAxMDTrBs3CJaq43ashR";
const SOL_LP_WAL = "GwBsj9GJdFrATQs1k9EYUyfaatKZDiViy8tkU9JP3TUL";
const SOL_LP_POS = "BJMyRCurUG45Lst2tZf2RMVbxwCopyWzxzHjgQz5ET6m";
const SOL_LP_INTRO = `Liquidity on Solana from Chord's own tape: adds, removes, fee claims, position opens and closes, decoded from the same blocks as the swaps. No key needed.

- **Venues.** Meteora DLMM, Meteora DAMM v2, Raydium CLMM and PumpSwap. Orca Whirlpools, Raydium CPMM / v4 and Meteora dynamic pools are not read yet.
- **Since.** \`since\` is when LP decoding started (2026-10-06 15:53 UTC); windows never start before it. A position opened earlier is \`partial: true\` and carries no PnL.
- **Fees are claimed fees.** An LP's fees appear when it claims them, so a window's fees understate what the pool earned, and one claim can hold days of fees.
- **Positions.** One row per position account (DLMM / DAMM v2 position, Raydium CLMM position NFT, PumpSwap LP token account), rebuilt from all its events. \`lower\` / \`upper\` are DLMM bin ids or Raydium CLMM ticks; null = full range. Realized PnL = withdrawn + fees claimed − deposited, only for a position seen from its open to its close with every amount priced. An open position's current value is not in the events: none is given.
- **Amounts** are whole tokens in the pool's own order (\`mintA\` / \`mintB\`); USD is valued when the event happened. Each add / remove / claim is checked against the pool vaults' balance changes in the same transaction (\`verified\`).
- **Addresses** are base58 and case-sensitive, as on the other Solana routes.`;
const SOL_LP_SIDES = { mintA: nullable(SOL_ADDR), symbolA: nullable(str("Creator-chosen.")), mintB: nullable(SOL_ADDR), symbolB: nullable(str("Creator-chosen.")) };
const SOL_LP_DEX = str("`meteora_dlmm` · `meteora_damm_v2` · `raydium_clmm` · `pumpswap`.");
const SolLpPosition = obj({
  position: nullable(SOL_ADDR), dex: SOL_LP_DEX, pool: nullable(SOL_ADDR), owner: nullable(SOL_ADDR), ...SOL_LP_SIDES,
  lower: nullable(int("DLMM bin id or CLMM tick.")), upper: nullable(int("")), status: { type: "string", enum: ["open", "closed"] },
  openedAt: nullable(SOL_TS), closedAt: nullable(SOL_TS), firstEvent: SOL_TS, lastEvent: SOL_TS, events: int(""),
  depositedA: nullable(num("Whole tokens.")), depositedB: nullable(num("")), withdrawnA: nullable(num("")), withdrawnB: nullable(num("")), feesA: nullable(num("Claimed.")), feesB: nullable(num("Claimed.")),
  depositedUsd: num(""), withdrawnUsd: num(""), feesClaimedUsd: num(""),
  realizedPnlUsd: nullable(num("Withdrawn + fees − deposited; null unless closed, not partial and fully priced.")),
  partial: bool("The tape did not see the open (opened before `since`); PumpSwap: more came out than the tape saw going in."), unpricedEvents: int("Value events without a USD price."),
}, "One Solana LP position.");
components.schemas.SolLpPosition = SolLpPosition;
const SOL_LP_EVENT = obj({ ts: SOL_TS, slot: int(""), signature: nullable(SOL_SIG), dex: SOL_LP_DEX, kind: { type: "string", enum: ["add", "remove", "fee", "open", "close"] },
  pool: nullable(SOL_ADDR), position: nullable(SOL_ADDR), owner: nullable(SOL_ADDR), amountA: nullable(num("Whole tokens.")), amountB: nullable(num("")), usd: nullable(num("")),
  lower: nullable(int("")), upper: nullable(int("")), verified: nullable(bool("true = matches the vault balance changes; null = could not be checked (shared vault, first deposit of a new pool)")) });
const SOL_LP_STATUS = q("status", { type: "string", enum: ["open", "closed", "all"], default: "all" }, "Which positions.");
const SOL_LP_HOURS = q("hours", { type: "integer", minimum: 1, maximum: 168, default: 24 }, "Window in hours, never before `since`.");
const SOL_LP_POOL_P = p("address", SOL_ADDR, "Pool address, base58.");

add("/chains/solana/lp/pools", "get", op(T.sol, "solLpPools", "Liquidity pools by LP activity", `Every pool where liquidity moved in the window, ranked: \`fees\` (claimed fees, default), \`deposits\`, \`withdrawals\`, \`net\` (net inflow), \`lps\` (distinct LPs) or \`tvl\`. Each row has the pool's TVL estimate and swap volume from the swap tape (TVL is null for most DLMM and CLMM pools: their swap events carry no reserve), deposits, withdrawals, claimed fees, counts and open positions. Cached 60 seconds.\n\n${SOL_LP_INTRO}`,
  { params: [q("sort", { type: "string", enum: ["fees", "deposits", "withdrawals", "net", "lps", "tvl"], default: "fees" }, ""), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, ""), SOL_LP_HOURS],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, sort: str(""), windowHours: int(""), since: SOL_TS, pools: int("Pools with activity in the window."),
      rows: arr(obj({ pool: SOL_ADDR, dex: SOL_LP_DEX, ...SOL_LP_SIDES, tvlUsd: nullable(num("")), priceUsd: nullable(num("")), token: nullable(SOL_ADDR), swapVolumeUsd: nullable(num("")),
        depositsUsd: num(""), withdrawalsUsd: num(""), netFlowUsd: num(""), feesClaimedUsd: num(""), adds: int(""), removes: int(""), claims: int(""), opens: int(""), closes: int(""), lps: int(""), openPositions: nullable(int("")) })),
      updatedAt: SOL_UPDATED }), ex("/v1/chains/solana/lp/pools?sort=fees&limit=2")), ...SOL_ERR("`BAD_LIMIT` / `BAD_HOURS` / `BAD_SORT`") } }));

add("/chains/solana/lp/top", "get", op(T.sol, "solLpTop", "LP wallets", `Wallets ranked over the LP positions active in the window: \`fees\` (claimed, default), \`deposits\` or \`pnl\` (realized). Many leaders are vaults and rebalancing bots; a short window is not a track record. Cached 60 seconds.\n\n${SOL_LP_INTRO}`,
  { params: [q("sort", { type: "string", enum: ["fees", "deposits", "pnl"], default: "fees" }, ""), q("limit", { type: "integer", minimum: 1, maximum: 100, default: 50 }, ""), SOL_LP_HOURS],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, sort: str(""), windowHours: int(""), since: SOL_TS,
      rows: arr(obj({ wallet: nullable(SOL_ADDR), positions: int(""), open: int(""), pools: int(""), depositedUsd: num(""), withdrawnUsd: num(""), feesClaimedUsd: num(""), realizedPnlUsd: nullable(num("")), realizedPositions: int(""), winRate: nullable(num("0–1.")) })),
      updatedAt: SOL_UPDATED }), ex("/v1/chains/solana/lp/top?sort=fees&limit=2")), ...SOL_ERR("`BAD_LIMIT` / `BAD_HOURS` / `BAD_SORT`") } }));

add("/chains/solana/lp/pool/{address}", "get", op(T.sol, "solLpPool", "One pool's liquidity", `Deposits, withdrawals, net flow and claimed fees over the window, and by hour; open positions and their owners; the pair with decimals, TVL estimate and swap volume. Cached 20 seconds.\n\n${SOL_LP_INTRO}`,
  { params: [SOL_LP_POOL_P, SOL_LP_HOURS],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, pool: SOL_ADDR, dex: SOL_LP_DEX, windowHours: int(""), since: SOL_TS, ...SOL_LP_SIDES, decimalsA: int(""), decimalsB: int(""),
      tvlUsd: nullable(num("")), priceUsd: nullable(num("")), token: nullable(SOL_ADDR), firstLpEvent: SOL_TS, swapVolumeUsd: nullable(num("")), depositsUsd: num(""), withdrawalsUsd: num(""), netFlowUsd: num(""), feesClaimedUsd: num(""),
      openPositions: int(""), openOwners: int(""), hourly: arr(obj({ hour: SOL_TS, depositsUsd: num(""), withdrawalsUsd: num(""), feesClaimedUsd: num(""), adds: int(""), removes: int(""), claims: int(""), opens: int(""), closes: int(""), lps: int("") })),
      updatedAt: SOL_UPDATED }), ex(`/v1/chains/solana/lp/pool/${SOL_LP_POOL}`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_HOURS`", { 404: errRes("`POOL_NOT_FOUND`: no liquidity event in this pool since LP decoding started, or its venue is not read.") }) } }));

add("/chains/solana/lp/pool/{address}/positions", "get", op(T.sol, "solLpPoolPositions", "A pool's positions", `The pool's positions, most recently active first. Cached 20 seconds.\n\n${SOL_LP_INTRO}`,
  { params: [SOL_LP_POOL_P, SOL_LP_STATUS, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, "")],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, pool: SOL_ADDR, status: str(""), since: nullable(SOL_TS), positions: arr(ref("SolLpPosition")), updatedAt: SOL_UPDATED }),
      ex(`/v1/chains/solana/lp/pool/${SOL_LP_POOL}/positions?status=open&limit=2`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_STATUS` / `BAD_LIMIT`") } }));

add("/chains/solana/lp/wallet/{address}", "get", op(T.sol, "solLpWallet", "A wallet's LP positions", `The wallet's positions as owner (DLMM: the position's owner, not an operator acting for it), most recently active first, with totals over every position of the \`status\` asked: deposited, withdrawn, claimed fees, realized PnL and win rate over positions seen open to close. Cached 15 seconds.\n\n${SOL_LP_INTRO}`,
  { params: [SOL_WAL_P, SOL_LP_STATUS, q("limit", { type: "integer", minimum: 1, maximum: 200, default: 100 }, "Rows; totals cover every position.")],
    responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, wallet: SOL_ADDR, status: str(""), since: nullable(SOL_TS), positions: int(""), open: int(""), closed: int(""), pools: int(""),
      depositedUsd: num(""), withdrawnUsd: num(""), feesClaimedUsd: num(""), realizedPnlUsd: nullable(num("")), realizedPositions: int(""), winRate: nullable(num("0–1.")), rows: arr(ref("SolLpPosition")), updatedAt: SOL_UPDATED }),
      ex(`/v1/chains/solana/lp/wallet/${SOL_LP_WAL}?limit=2`)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_STATUS` / `BAD_LIMIT`") } }));

for (const [by, opId, title, key] of [
  ["pool", "solLpPoolEvents", "A pool's liquidity events", `/v1/chains/solana/lp/pool/${SOL_LP_POOL}/events?limit=2`],
  ["wallet", "solLpWalletEvents", "A wallet's liquidity events", `/v1/chains/solana/lp/wallet/${SOL_LP_WAL}/events?limit=2`],
  ["position", "solLpPositionEvents", "One position's events", `/v1/chains/solana/lp/position/${SOL_LP_POS}/events?limit=2`],
]) {
  add(`/chains/solana/lp/${by}/{address}/events`, "get", op(T.sol, opId, title, `Adds, removes, fee claims, opens and closes, newest first${by === "wallet" ? " (the wallet as the position's owner)" : ""}. A close row of a DLMM \`close_position2\` or a Raydium CLMM position has no \`pool\`: the instruction does not carry it.\n\n${SOL_LP_INTRO}`,
    { params: [p("address", SOL_ADDR, `${by[0].toUpperCase()}${by.slice(1)} address, base58.`), q("limit", { type: "integer", minimum: 1, maximum: 200, default: 50 }, ""), SOL_BEFORE],
      responses: { 200: ok("", obj({ chain: { type: "string", const: "solana" }, [by === "wallet" ? "owner" : by]: SOL_ADDR, events: arr(SOL_LP_EVENT), nextBefore: nullable(SOL_TS) }), ex(key)), ...SOL_ERR("`BAD_ADDRESS` / `BAD_LIMIT` / `BAD_CURSOR`") } }));
}

// Streaming (documented as operations so they appear in the reference; protocol detail lives in Concepts → Streaming) ──
add("/stream/market", "get", op(T.stream, "streamMarket", "Server-sent events: prices", `One \`text/event-stream\` feed, no key, EventSource-friendly with automatic reconnect. Events: \`rh-ticker\` (fresh prices for chain 4663, about every 10 s, only addresses whose price moved), \`ticker\` / \`whales\` / \`defi\` (Monad), \`ping\` every 5 s. Capacity 500 clients (\`503\` beyond). Arc and Robinhood Chain boards stream faster over the WebSocket \`prices\` channel — see Concepts → Streaming.`,
  { responses: { 200: { description: "`text/event-stream`", content: { "text/event-stream": { schema: { type: "string" }, example: 'event: rh-ticker\ndata: {"items":[{"address":"0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec","priceUsd":220.97,"change24h":-0.71}]}\n\nevent: ping\ndata: 1789891855\n' } } }, 503: errRes("At capacity.") } }));
add("/ws/live", "get", op(T.stream, "wsLive", "WebSocket: live candles, trades and board feeds", `Upgrade to a WebSocket. No key needed, rate-limit exempt, up to 8 channels per connection. With an API key (\`X-API-Key\`, or \`?apiKey=\` from a browser) the connection joins a separate pool: up to 64 channels per connection and 20 connections per key (\`429\` beyond). Subscribe with \`{op:"sub", channel:"candles", token, tf}\`, \`{op:"sub", channel:"trades", token}\` or \`{op:"sub", channel:"prices", chain}\` (chain \`5042\`, \`4663\` or \`143\`); the server pushes \`candle\`, \`trades\` and \`prices\` frames (every print within ~400 ms; on 5042 / 4663 each item also carries the token's live 24h volume and trade counts), \`new\` frames for tokens trading for the first time (5042 / 4663), \`ping\` every 25 s, and \`error\` with a code (\`bad_op\` · \`bad_token\` · \`bad_tf\` · \`bad_chain\` · \`channel_cap\`). Full protocol under Concepts → Streaming.`,
  { responses: { 101: { description: "Switching protocols." }, 429: errRes("This API key already holds its maximum of live connections."), 503: errRes("`WS_LIVE_DISABLED` or at capacity.") } }));

// Account and health ───────────────────────────────────────────────────────────────────────────
add("/me", "get", op(T.account, "me", "Your key's plan and usage", "The tier, limits and usage (today, this month) behind an API key. Keys are created on getchord.xyz/developer after a Google sign-in.", { security: [{ ApiKey: [] }], responses: withErr({ 200: ok("", obj({ email: nullable(str("")), tier: { type: "string", enum: ["free", "builder", "pro"] }, limits: obj({ rpm: int(""), monthly: int(""), priceUsd: num(""), label: str("") }), usage: obj({ today: int(""), month: int("") }) }), { email: "you@example.com", tier: "free", limits: { rpm: 60, monthly: 100000, priceUsd: 0, label: "Free" }, usage: { today: 41, month: 1209 } }) }, [401]) }));
add("/health", "get", op(T.account, "health", "Service health", "Engine, cache and pool-sync state. `503` when the routing engine is unreachable.", { responses: withErr({ 200: ok("", obj({ status: str(""), version: str(""), uptime: num("Seconds."), engine: obj({ status: str(""), latencyMs: int("") }), redis: obj({ status: str("") }), poolCount: int(""), lastSyncBlock: int("") }), ex("/v1/health")) }, [503]) }));

// ── document ──────────────────────────────────────────────────────────────────────────────────
const doc = {
  openapi: "3.1.0",
  info: {
    title: "Chord API",
    version: "2026-10-05",
    summary: "Trade, data and agent endpoints for Arc (5042) and Robinhood Chain (4663), plus chain data for Avalanche (43114), Base (8453), BNB Chain (56) and Solana (read-only).",
    description: `Chord is a non-custodial trading app and on-chain data index. The API has three kinds of endpoint:

- **Trade**: \`/quote\` finds the best route across every venue on the chain; \`/swap\` turns it into a transaction you sign yourself. Chord never holds funds or keys.
- **Read**: every swap on the chain, rolled up by token, venue and hour, from Chord's own index — tokens, launches, holders, top wallets, portfolio PnL, liquidity positions and pools. No key needed. Avalanche, Base and BNB Chain have the same rollups under \`/chains/{chain}/*\`; Solana has its own read-only family under \`/chains/solana/*\` (base58 addresses, case-sensitive).
- **Agent**: the analyst (\`/ask\`) and the streams.

Amounts are decimal strings in the token's smallest unit. Timestamps are Unix seconds unless the field is \`updatedAt\` (milliseconds). Reads answer anonymous callers at 60 requests a minute per IP; an \`X-API-Key\` header raises that to your plan. Every non-2xx body is \`{ error, message }\`.`,
    contact: { name: "Chord", url: "https://getchord.xyz/developer" },
    "x-logo": { url: "https://getchord.xyz/chord/pwa-192x192.png" },
  },
  servers: [{ url: "https://api.getchord.xyz/v1", description: "Production" }],
  tags: [
    { name: T.swap, description: "Best-route quotes across every venue on the chain, and the unsigned transaction to execute them." },
    { name: T.meta, description: "One quote and one unsigned transaction on any Chord chain, for agents. Chord's own router answers first; a third-party aggregator (KyberSwap, Monorail, LI.FI, Relay) only when Chord fails, never for a better price. Every answer names the provider, and a fallback transaction is returned only when its router is on Chord's allowlist and it passed a simulation run as the taker." },
    { name: T.arc, description: "Arc (chain 5042): chain totals, every token traded, launches, launchers, holders — from Chord's own rollup and index tables." },
    { name: T.tokens, description: "Curated lists, candles, trade tapes, windowed stats and logos. Address-keyed routes serve both chains." },
    { name: T.wallets, description: "Wallets ranked from the tape by a skill-adjusted score, with routers and bots removed." },
    { name: T.portfolio, description: "Average-cost PnL, trade history and a daily calendar for any wallet." },
    { name: T.lp, description: "Liquidity: events, pools ranked for providers, positions valued live, LP leaderboard, range planning and backtests, alerts." },
    { name: T.points, description: "The Chord points program on Arc." },
    { name: T.ask, description: "The analyst agent over the Arc index, its picks and research notes." },
    { name: T.bridge, description: "Circle CCTP fast transfer to Arc, and LI.FI routes from 60+ chains." },
    { name: T.rh, description: "Robinhood Chain (chain 4663): chain totals, tokens and tokenized stocks from the rollup tables." },
    { name: T.chains, description: "Avalanche C-Chain (43114), Base (8453) and BNB Chain (56): chain totals, the 24-hour token board, prints, one token's tape, venue share and a wallet's PnL, from Chord's own index of every swap on those chains. One set of routes, the chain in the path." },
    { name: T.sol, description: "Solana, read-only: chain totals, the 24-hour token board, search, one token's stats, prints, candles and traders, the day's trader board, a wallet's PnL, and liquidity (LP pools, positions, events, LP wallets on Meteora DLMM / DAMM v2, Raydium CLMM and PumpSwap), from Chord's own tape of the swap events of 11 Solana venues (PumpSwap, pump.fun, Meteora, Raydium, Orca). Prop AMMs and order books are not read. Addresses are base58 and case-sensitive; the path segment is the literal `solana`. Read the notes on each operation before comparing these numbers with an all-market source." },
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
