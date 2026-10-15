# chord-agent

A stdio bridge to the hosted Chord MCP server, plus a function-calling manifest.

The tools live in the API (`POST https://api.getchord.xyz/v1/mcp`, source `packages/api/src/services/mcp/tools.ts`).
This package only carries the protocol: it lists and calls those tools over HTTP, so a new or changed tool reaches every
install without a release. 17 tools today; every data tool takes a `chain` (`monad`, `robinhood`, `arc`, `avalanche`,
`base`, `bnb`, `arbitrum`, `solana`). Nothing signs or sends: `chord_swap_tx` returns an unsigned transaction for the caller's wallet.

**Use the hosted server directly when your client speaks HTTP** (Claude Code, Claude Desktop, Cursor):

```bash
claude mcp add --transport http chord https://api.getchord.xyz/v1/mcp
```

This package is for clients that only speak stdio, and for calling the tools from code.

**Availability.** Not published to npm; the source is public at https://github.com/getchordlabs/chord (folder `agent/`).
Most developers use the hosted server (MCP Registry name `io.github.getchordlabs/chord`), the manifest at
https://api.getchord.xyz/v1/mcp/tools.json, the Agent skill (https://getchord.xyz/docs/agents/skill/) and the REST API.
Public docs: https://getchord.xyz/docs/agents/mcp/.

## stdio

```bash
cd packages/agent && pnpm install && pnpm build
claude mcp add chord -- node /absolute/path/to/packages/agent/dist/mcp.js
```

```json
{
  "mcpServers": {
    "chord": {
      "command": "node",
      "args": ["/absolute/path/to/packages/agent/dist/mcp.js"],
      "env": { "CHORD_API_KEY": "optional", "CHORD_CHAIN": "optional default chain, e.g. arc" }
    }
  }
}
```

## In code

```ts
import { listTools, runTool, toolManifest } from "chord-agent";

const chains = await runTool("chord_chains");                    // what each chain supports
const board = await runTool("chord_tokens", { chain: "base", limit: 5 });
const quote = await runTool("chord_quote", { chain: "arc", tokenIn: "0x3600…", tokenOut: "0xbef5…", amount: "10000000" });
// every answer: { chain, route, data } — `route` is the REST call that produced it
```

`toolManifest()` returns the list as OpenAI-style function definitions. `pnpm manifest` writes it to `tools.json` and
copies it to `packages/web/public/agent/tools.json` (served at https://getchord.xyz/agent/tools.json).

## Environment

- `CHORD_API_URL`: default `https://api.getchord.xyz`
- `CHORD_API_KEY`: optional; raises the rate limit to your plan, `chord_ask` needs one. Keys: https://getchord.xyz/developer
- `CHORD_CHAIN`: optional; pins a default chain so `chain` may be left out

## Check

`pnpm smoke` lists the tools and calls overview, tokens and a quote on every chain against the live API, one line each.
It exits 1 when any call fails.
