# Chord

Non-custodial trading API and AI agent. One quote call finds the best route across the DEXs of eight EVM chains
(Ethereum, Monad, Robinhood Chain, Arc, Avalanche, Base, BNB Chain and Arbitrum One), and one router contract executes
it in a single transaction. Next to trading, Chord keeps a live index of swaps, holders, LP positions and wallet PnL on those
chains and on Solana, which apps and AI agents can query.

- App (Ask, AI trading agent + wallet): https://getchord.xyz/ask
- Docs and API reference: https://getchord.xyz/docs
- API: https://api.getchord.xyz/v1 (what each chain serves: https://api.getchord.xyz/v1/chains)
- Status, measured every minute from Cloudflare: https://getchord.xyz/status
- Hosted MCP server: `https://api.getchord.xyz/v1/mcp`

Chord started as NullTerminal, a DEX aggregator on Monad. Contract and package names that start with `Null` come
from that period; the `Chord*` contracts in `contracts/src/chord/` are the current builds of the same code.

## Use it from an AI agent

The hosted MCP server needs no key and no install (Streamable HTTP). `?chain=<key>` pins a default chain.

```bash
claude mcp add --transport http chord https://api.getchord.xyz/v1/mcp
```

17 tools, each taking a `chain`: `chord_chains`, `chord_status`, `chord_overview`, `chord_tokens`, `chord_search`,
`chord_token`, `chord_trades`, `chord_candles`, `chord_wallet`, `chord_wallet_trades`, `chord_smart_money`,
`chord_holders`, `chord_lp_pools`, `chord_lp_positions`, `chord_quote`, `chord_swap_tx` and `chord_ask`. Nothing signs
or sends: `chord_swap_tx` returns an unsigned transaction, the approval it needs and a simulation run as the taker.

Listed in the official MCP Registry as `io.github.getchordlabs/chord` (`server.json` in this repository) and on
Smithery as [tuantqse90/chord](https://smithery.ai/servers/tuantqse90/chord). Other ways in: the REST API with its
OpenAPI spec (`openapi/`), the Agent Skill (`skills/chord/`), the Docs MCP at https://getchord.xyz/docs/mcp and the
function-calling manifest at https://api.getchord.xyz/v1/mcp/tools.json.

## Chains

| Chain | Chain id | Swaps (quote + unsigned transaction) | Data |
|---|---|---|---|
| Ethereum | 1 | yes | tokens, trades, candles, wallet PnL |
| Monad | 143 | yes | tokens, trades, candles, wallet PnL, smart money, LP |
| Robinhood Chain | 4663 | yes | tokens, trades, candles, wallet PnL, smart money, holders, LP |
| Arc | 5042 | yes | tokens, trades, candles, wallet PnL, smart money, holders, LP |
| Avalanche C-Chain | 43114 | yes | tokens, trades, candles, wallet PnL |
| Base | 8453 | yes | tokens, trades, candles, wallet PnL |
| BNB Chain | 56 | yes | tokens, trades, candles, wallet PnL |
| Arbitrum One | 42161 | yes | tokens, trades, candles, wallet PnL |
| Solana | none | no | tokens, trades, candles, wallet PnL, smart traders, LP |

`GET /v1/chains` answers the same table with the route behind each capability.

## What is in this repository

| Folder | Contents |
|---|---|
| `contracts/` | Foundry project: ChordRouter (UUPS), AdapterRegistry, FeeCollector, one adapter per venue family (Uniswap V2/V3/V4, Algebra and Algebra Integral, Solidly, Liquidity Book, PancakeSwap Infinity, Metric, WOOFi, DODO V2, ERC-4626 deposit, Curve, Balancer and more), RhStockZap / RhTokenZap for cross-chain buys on Robinhood Chain, SwapAndBridgeCCTP, deploy scripts and fork tests per chain |
| `agent/` | `chord-agent`: a stdio bridge to the hosted MCP server for clients that only speak stdio, and the function-calling manifest (`tools.json`) |
| `skills/chord/` | Agent Skill for Claude Code, Codex and other agents: `SKILL.md`, references with live API output, `chord.py` client |
| `docs-mcp/` | Docs MCP server (stdio, and hosted at https://getchord.xyz/docs/mcp) |
| `openapi/` | OpenAPI spec of the public API (`openapi.json`) and the script that builds it |
| `sdk/` | The original TypeScript SDK from the Monad period |

The routing engine (Rust) and the API server (TypeScript) are not in this repository. They run behind
`api.getchord.xyz`.

## Contracts

The three proxies sit at the same addresses on all eight EVM chains (aligned deployer nonces):

| Contract | Address |
|---|---|
| ChordRouter (UUPS proxy) | `0x1b1fee89a381e595fe6536b99ba91f3e16e9601a` |
| AdapterRegistry (UUPS proxy) | `0x6cf25d2af1a58d7094b0ac253ae616a8e1f2ea3f` |
| FeeCollector (UUPS proxy) | `0x6c66229675fd9ceda9a9b2ea2bd983b3d8255834` |

Every adapter pins the router as an immutable and reverts `NotRouter` for any other caller. The router only calls
adapters the registry approves. Fees are set on-chain by `FeeCollector.feeBpsFor(outputToken)`: 5 bps by default on
every chain, 0 bps for stablecoins, majors and the listed tokenized stocks on Robinhood Chain.

### Robinhood Chain (chain id 4663)

| Contract | Address |
|---|---|
| ChordRouter implementation (upgraded 2026-10-02) | `0x209e38890533469337488588cB9e4A44943EE8FE` |
| Uniswap V4 adapter | `0x3622116c527896Ab9C1510A45f3344AaBD03973a` |
| V3 any-fork adapter (Uniswap V3, Ramses and other V3 forks) | `0x3A7D13a420c8FBC29Bf4A1feDB22A5Dae3A8913E` |
| V2 adapter | `0xC4b930D9E5d20cc8b4C67f2118FE0cD8E6e36b72` |
| Algebra adapter | `0x63bd5402aCC3129c9b38c7d52f327b82f24B497D` |
| RhStockZap | `0x66627Ce32af8801525930B7C2a1Db4905193bb51` |

Router upgrade on Robinhood Chain: tx `0x9111f311319d778d2b53cce16fe7d471a15e61b8e00bdd08de074a5bcc571aa3`.

### Arbitrum One (chain id 42161, deployed 2026-10-14)

| Contract | Address |
|---|---|
| ChordRouter implementation | `0x1cd8CeED960dE0c9787295c8F1BF278D4A36698c` |
| ChordV3Adapter (Uniswap V3, PancakeSwap V3, SushiSwap V3) | `0xd55fe37e30435cF15fe2C7fcAAF1aBf19d13b195` |
| ChordV2Adapter (Uniswap V2, SushiSwap V2) | `0xa61C202C4c989a1724E1B432C96A9f064856574d` |
| ChordV4Adapter | `0xFE82b7714c36083AB518067f03680C59ac57840a` |
| ChordMetricV1Adapter | `0x4e48D8bEDB4A781493e6193776FDa37e57Ce07b1` |
| ChordAlgebraIntegralAdapter (Camelot V3) | `0x3D26860E5d5ddE28FDcd11e14573CE7b103fA081` |
| ChordWooFiAdapter | `0xfdC2e11793197B9D16Ae1eDBa8049dcc9Fc15748` |
| ChordDodoV2Adapter | `0x3E46e23C171aAC3124D85BbCa33A2C0422342fA4` |

All verified on Sourcify. Each venue was swapped both ways on mainnet through the router before the engine routed it.

### Ethereum (chain id 1, deployed 2026-10-15)

Same addresses as on Arbitrum One for the router implementation and the three core adapters:

| Contract | Address |
|---|---|
| ChordRouter implementation | `0x1cd8CeED960dE0c9787295c8F1BF278D4A36698c` |
| ChordV3Adapter (Uniswap V3, PancakeSwap V3, SushiSwap V3) | `0xd55fe37e30435cF15fe2C7fcAAF1aBf19d13b195` |
| ChordV2Adapter (Uniswap V2, SushiSwap V2) | `0xa61C202C4c989a1724E1B432C96A9f064856574d` |
| ChordV4Adapter | `0xFE82b7714c36083AB518067f03680C59ac57840a` |

All 9 contracts of the stack match on Sourcify; every venue was swapped both ways on mainnet before going public.

## Build and test

```bash
git submodule update --init --recursive
cd contracts
forge build
forge test --no-match-contract 'ForkTest$'
```

## Since the buildathon (Oct 5 to Oct 15, 2026)

- **Arbitrum One**: aligned Chord stack, deploy script and fork test (`edd957a`), swaps and the Ask side (`c28203c`),
  public on Oct 15 (`ca79736`).
- **Ethereum**: aligned Chord stack, deploy script and fork test (`79233bc`), swaps and the Ask side (`8a46f39`),
  tokens that need `approve(0)` first such as USDT (`69a06af`), public on Oct 15 (`38b466e`).
- **New venues**: Metric v1 on Monad and Avalanche (`80daf2c`, `23bfe8c`), ERC-4626 deposit on Monad, which mints
  aprMON, shMON and gMON at the vault's rate when pools price below it (`a41a703`), WOOFi (`83283af`), Camelot V3
  through the Algebra Integral adapter (`454091c`), DODO V2 on Avalanche and Arbitrum (`1975d08`), LFJ Liquidity Book
  v2.1 (`147f862`), and two concentrated-liquidity factories on Arc through ChordV3Adapter r3 (`95e65be`).
- **Agents**: the stdio agent became a bridge to the hosted MCP server (`02f7201`), wallet trades on every chain
  (`5256c20`), Solana data, smart traders and LP routes in the OpenAPI spec and the skill (`710b14d`, `74957c2`,
  `d13d3ef`), a docs page per network (`0306a08`).

## Work done during the Arbitrum Open House Singapore Buildathon (Sep 13 to Oct 4, 2026)

Chord existed before the buildathon. This repository was extracted from our monorepo with its real commit history
for these folders, so every commit dated 2026-09-13 or later was made during or after the buildathon
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

MIT, see [`LICENSE`](LICENSE). It covers everything in this repository: contracts, agent, skill, Docs MCP, OpenAPI spec
and SDK. The submodules in `contracts/lib/` keep their own licenses (OpenZeppelin MIT, forge-std MIT or Apache-2.0).
Sources verified on-chain before 2026-10-15 still read `SPDX-License-Identifier: UNLICENSED`; the code is the same and
is MIT from that date.
