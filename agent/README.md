# chord-agent

The Chord agent harness: nine tools over the Chord API, exposed as an MCP server and as a
function-calling manifest. Stock tokens on chain 4663: prices, the stock screener, one stock in
depth, best-route quotes with swap calldata, smart money, and any wallet's PnL.

Every tool is a read except `chord_swap_tx`, which returns an unsigned transaction. Chord never
signs and never holds funds: the agent's own wallet signs.

## Tools

| Tool | What it returns |
| --- | --- |
| `chord_overview` | 24h volume, swaps, tokens traded, venues and their share |
| `chord_search_tokens` | listed tokens matching a symbol, name or address |
| `chord_price` | live price, 24h change, volume, trades for one token |
| `chord_stocks` | every tokenized stock: price, change, volume, buy share, after-hours share, gap to NAV |
| `chord_stock` | one stock in depth: activity windows, ATH, first trade, pools |
| `chord_quote` | best route across every venue, expected output, price impact, the route |
| `chord_swap_tx` | the unsigned transaction for a quote, for the agent's wallet to sign |
| `chord_smart_money` | wallets ranked from the tape, routers and bots removed |
| `chord_wallet_pnl` | realized and open profit per token for one wallet |

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
      "env": { "CHORD_API_KEY": "optional, raises the rate limit" }
    }
  }
}
```

Claude Code: `claude mcp add chord -- node /absolute/path/to/packages/agent/dist/mcp.js`.

## Function calling (OpenAI-style, LangChain, anything that takes a manifest)

`tools.json` in this folder, or `https://getchord.xyz/agent/tools.json`, is the same nine tools as
JSON Schema. Call the API yourself with the arguments the model produces; the base URL and the
optional `X-API-Key` header are in the manifest.

```ts
import { runTool, tools } from "chord-agent";
const quote = await runTool("chord_quote", { tokenIn: "ETH", tokenOut: "NVDA", amount: "0.1" });
```

## Environment

- `CHORD_API_URL` — default `https://api.getchord.xyz`
- `CHORD_API_KEY` — optional; reads work without one at a lower limit. Keys come from https://getchord.xyz/developer

## Check

`pnpm smoke` calls every read tool once against the live API and prints one line each.
