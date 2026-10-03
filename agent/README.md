# chord-agent

The Chord agent harness: 19 tools over the Chord API, exposed as an MCP server and as a
function-calling manifest. Robinhood Chain (4663): prices, the stock screener, one stock in depth,
best-route quotes with swap calldata, smart money and any wallet's PnL. Arc (5042): chain totals,
the 24h token board, one token in depth, venue share. Liquidity (5042 by default, 4663 or 143):
pools ranked for providers, a wallet's positions, the LP leaderboard. Plus `chord_ask`, the analyst.

Every tool is a read except `chord_swap_tx`, which returns an unsigned transaction. Chord never
signs and never holds funds: the agent's own wallet signs.

**Availability.** Not published to npm, and this repository is not public. It runs only from a
checkout of this repository. Outside developers use the public pieces instead: the REST API
(https://getchord.xyz/docs/api-reference/), the manifest at https://getchord.xyz/agent/tools.json,
the Agent skill (https://getchord.xyz/docs/agents/skill/) and the hosted Docs MCP
(https://getchord.xyz/docs/mcp). The public docs page is https://getchord.xyz/docs/agents/mcp/;
keep its tool table in step with `src/tools.ts`.

## Tools

| Tool | Chain | What it returns |
| --- | --- | --- |
| `chord_overview` | 4663 | 24h volume, swaps, tokens traded, venues and their share |
| `chord_search_tokens` | 4663 | up to 10 listed tokens matching a symbol, name or address |
| `chord_price` | 4663 | live price, 24h change, volume, trades for one token |
| `chord_stocks` | 4663 | every tokenized stock: price, change, volume, buy share, after-hours share, gap to NAV |
| `chord_stock` | 4663 | one stock in depth: activity windows, ATH, first trade, pools |
| `chord_quote` | 4663 | best route across every venue, expected output, price impact, the route |
| `chord_swap_tx` | 4663 | the unsigned transaction for a quote, for the agent's wallet to sign |
| `chord_meta_quote` | all six | **quote here first**: Chord's router, or a third-party aggregator only when Chord fails; `provider` + `fallbackReason` say who answered; with `wallet` also the unsigned transaction, approval and a simulation |
| `chord_meta_swap_tx` | all six | the unsigned transaction for a meta quote (`quoteId`) or a pair + amount, with its approval and simulation |
| `chord_smart_money` | 4663 | wallets ranked from the tape, routers and bots removed |
| `chord_wallet_pnl` | 4663 | realized and open profit per token for one wallet |
| `chord_arc_overview` | 5042 | 24h volume in USDC, swaps, venues, coverage |
| `chord_arc_tokens` | 5042 | tokens traded in the last 24h, listed or not, with on-chain symbol/name |
| `chord_arc_token` | 5042 | one token: identity, hourly series, venue split, every indexed pool |
| `chord_arc_venues` | 5042 | per-venue daily volume and share for 1..180 days |
| `chord_lp_pools` | 5042 / 4663 / 143 | pools ranked for a liquidity provider: TVL, volume, fees, fee/TVL, APR, LP flow |
| `chord_lp_positions` | 5042 / 4663 / 143 | a wallet's V3/V4 positions: range, in range, value, fees, PnL, summary |
| `chord_lp_leaderboard` | 5042 / 4663 / 143 | top liquidity providers: profit by window, win rate, fees, positions |
| `chord_ask` | Arc | the analyst: a researched answer with sources (needs `CHORD_API_KEY`) |

`chord_quote` / `chord_swap_tx` have no chain argument: both tokens resolve against the 4663 list.

## MCP (Claude Desktop, Claude Code, Cursor, any MCP client)

```bash
cd packages/agent && pnpm install && pnpm build
```

```json
{
  "mcpServers": {
    "chord": {
      "command": "node",
      "args": ["/absolute/path/to/packages/agent/dist/mcp.js"],
      "env": { "CHORD_API_KEY": "optional, raises the rate limit; required for chord_ask" }
    }
  }
}
```

Claude Code: `claude mcp add chord -- node /absolute/path/to/packages/agent/dist/mcp.js`.

## Function calling (OpenAI-style, LangChain, anything that takes a manifest)

`tools.json` in this folder, or `https://getchord.xyz/agent/tools.json`, is the same 19 tools as
JSON Schema. Call the API yourself with the arguments the model produces; the base URL and the
optional `X-API-Key` header are in the manifest. `pnpm manifest` regenerates it from `src/tools.ts`
and copies it to `packages/web/public/agent/tools.json` (the served copy).

Inside this repository the package also exports the tools:

```ts
import { runTool, tools } from "chord-agent";
const quote = await runTool("chord_quote", { tokenIn: "ETH", tokenOut: "NVDA", amount: "0.1" });
```

## Environment

- `CHORD_API_URL`: default `https://api.getchord.xyz`
- `CHORD_API_KEY`: optional; reads work without one at a lower limit, `chord_ask` needs one. Keys come from https://getchord.xyz/developer

## Check

`pnpm smoke` calls the Robinhood Chain and Arc read tools once against the live API and prints one line each
(the LP tools and `chord_ask` are not in it).
