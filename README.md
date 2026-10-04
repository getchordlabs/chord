# Chord

Non-custodial trading API and AI agent. One quote call finds the best route across the DEXs of Robinhood Chain,
Arc, Monad, Avalanche, Base and BNB Chain, and one router contract executes it in a single transaction. Next to
trading, Chord keeps a live index of swaps, holders and wallet PnL that apps and AI agents can query.

- App (Ask, AI trading agent + wallet): https://getchord.xyz/ask
- Docs and API reference: https://getchord.xyz/docs
- API: https://api.getchord.xyz/v1 (Robinhood Chain overview: https://api.getchord.xyz/v1/rh/overview)

Chord started as NullTerminal, a DEX aggregator on Monad. Contract and package names that start with `Null` come
from that period; the `Chord*` contracts in `contracts/src/chord/` are the current builds of the same code.

## What is in this repository

| Folder | Contents |
|---|---|
| `contracts/` | Foundry project: ChordRouter (UUPS), AdapterRegistry, FeeCollector, one adapter per venue family (Uniswap V2/V3/V4, Algebra, Solidly, Liquidity Book, PancakeSwap Infinity, Curve, Balancer and more), RhStockZap / RhTokenZap for cross-chain buys on Robinhood Chain, SwapAndBridgeCCTP |
| `agent/` | `chord-agent`: tool definitions (`tools.json`) and an MCP stdio server for AI agents |
| `skills/chord/` | Agent Skill for Claude Code, Codex and other agents: `SKILL.md`, references with live API output, `chord.py` client |
| `docs-mcp/` | Docs MCP server (stdio, and hosted at https://getchord.xyz/docs/mcp) |
| `openapi/` | OpenAPI spec of the public API (`openapi.json`) and the script that builds it |
| `sdk/` | The original TypeScript SDK from the Monad period |

The routing engine (Rust) and the API server (TypeScript) are not in this repository. They run behind
`api.getchord.xyz`.

## Robinhood Chain (chain id 4663)

| Contract | Address |
|---|---|
| ChordRouter (UUPS proxy) | `0x1b1fee89a381e595fe6536b99ba91f3e16e9601a` |
| ChordRouter implementation (upgraded 2026-10-02) | `0x209e38890533469337488588cB9e4A44943EE8FE` |
| AdapterRegistry (UUPS proxy) | `0x6cf25d2af1a58d7094b0ac253ae616a8e1f2ea3f` |
| FeeCollector (UUPS proxy) | `0x6c66229675fd9ceda9a9b2ea2bd983b3d8255834` |
| Uniswap V4 adapter | `0x3622116c527896Ab9C1510A45f3344AaBD03973a` |
| V3 any-fork adapter (Uniswap V3, Ramses and other V3 forks) | `0x3A7D13a420c8FBC29Bf4A1feDB22A5Dae3A8913E` |
| V2 adapter | `0xC4b930D9E5d20cc8b4C67f2118FE0cD8E6e36b72` |
| Algebra adapter | `0x63bd5402aCC3129c9b38c7d52f327b82f24B497D` |
| RhStockZap | `0x66627Ce32af8801525930B7C2a1Db4905193bb51` |

The three proxies sit at the same addresses on all six chains (aligned deployer nonces). Every adapter pins the
router as an immutable and reverts `NotRouter` for any other caller. The router only calls adapters the registry
approves. Router upgrade on Robinhood Chain: tx
`0x9111f311319d778d2b53cce16fe7d471a15e61b8e00bdd08de074a5bcc571aa3`.

Fees are set on-chain by `FeeCollector.feeBpsFor(outputToken)`: 5 bps by default, 0 bps when the output is USDG,
WETH or one of the listed tokenized stocks on Robinhood Chain.

## Build and test

```bash
git submodule update --init --recursive
cd contracts
forge build
forge test --no-match-contract 'ForkTest$'
```

## Work done during the Arbitrum Open House Singapore Buildathon (Sep 13 to Oct 4, 2026)

Chord existed before the buildathon. This repository was extracted from our monorepo with its real commit history
for these folders, so every commit dated 2026-09-13 or later was made during the buildathon
(`git log --since=2026-09-13`). Highlights:

- **ChordRouter**: Chord-named implementations of router, registry and fee collector (`08dcb96`), and a script that
  upgrades only the router proxy, used on Robinhood Chain, Monad and Arc on Oct 2 (`dfb5386`).
- **Robinhood Chain cross-chain buys**: RhTokenZap, a generic destination zap through the router, and
  SwapAndBridgeCCTP, swap plus Circle CCTP burn in one call (`9814cba`).
- **New adapters**: UniV2TaxSafeAdapter, priced from what the pair actually received (`0dc387b`); Uniswap V4 with
  native USDC on Arc (`0cc5ff3`); ChordSolidlyAdapter (`3775c10`, `f9a6fae`); ChordLBPairAdapter (`b3136f1`);
  ChordAlgebraIntegralAdapter (`b20d1de`); ChordInfinityCLAdapter (`95db92d`).
- **Agent surfaces**: Agent Skill (`014875e`), Docs MCP (`54ffb71`), agent tools for Arc, LP and the
  meta-aggregator (`98cd499`, `d751aeb`, `ad9f222`), OpenAPI spec kept in line with the API (`3c4ea54`, `5130d2a`).
- **Ask wallet on Robinhood Chain** (mostly in the closed API and web app, partly here): USDC on Arbitrum converts
  to USDG on Robinhood Chain with one signature (`609f37a`), explicit Convert and multi-chain wallet (`f2b4244`).

## License

All rights reserved. The source is public for review; no license to reuse it is granted (most contracts carry `SPDX-License-Identifier: UNLICENSED`).
