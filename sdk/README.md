# @nullterminal/sdk

DEX aggregator SDK for Monad. Optimal swap routes across 8 DEXs, split orders, single transaction. Honest, executable quotes only.

## Install

```bash
npm install @nullterminal/sdk
```

## Quick Start

```typescript
import { NullTerminal } from "@nullterminal/sdk";

const nt = new NullTerminal();

// 1. Get best quote
const quote = await nt.getQuote({
  inputMint: "0x0000000000000000000000000000000000000000", // MON
  outputMint: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", // USDC
  amount: (1000n * 10n ** 18n).toString(), // 1000 MON in wei
});

console.log(`Output: ${quote.outputAmount} USDC`);
console.log(`Route: ${quote.routePlan.map(s => s.swapInfo.dex).join(" → ")}`);

// 2. Build unsigned transaction
const { transaction } = await nt.buildSwap({
  quoteResponse: quote,
  userPublicKey: "0xYourWalletAddress",
});

// 3. Sign with any wallet library
// ethers: await signer.sendTransaction(transaction)
// viem:   await walletClient.sendTransaction(transaction)
// wagmi:  await sendTransaction(transaction)
```

## API

### `new NullTerminal(config?)`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `baseUrl` | string | `https://api.nullterminal.xyz` | API endpoint |
| `apiKey` | string | — | API key for higher rate limits |

### `nt.getQuote(params)`

Find the best swap route across all DEXs.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `inputMint` | string | Yes | Token address to sell |
| `outputMint` | string | Yes | Token address to buy |
| `amount` | string | Yes | Amount in wei |
| `slippageBps` | number | No | Slippage (default: 50 = 0.5%) |

### `nt.buildSwap(params)`

Build an unsigned transaction from a quote.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `quoteResponse` | QuoteResponse | Yes | Quote from `getQuote()` |
| `userPublicKey` | string | Yes | Wallet address |
| `feeAccount` | string | No | Referral address (earns 50% of the 5bps fee) |

Slippage is **not** set here — it is baked into the quote's `otherAmountThreshold` at quote time via `getQuote`'s `slippageBps`.

Returns `{ transaction: { to, data, value, gasLimit, chainId } }`

### `nt.getTokens()`

Returns the full curated token list — each token carries `verified` (on the official list) and `liquidityUsd`.

### `nt.searchTokens(query)`

On-chain discovery: find swap-ready tokens by symbol or name that are **not** in the curated list. Results are logo-gated with real on-chain decimals and flagged `verified: false`.

```typescript
const results = await nt.searchTokens("gmon");
```

### `nt.getTokenMarkets()`

Market data (`priceUsd`, `change24h`, `volume24h`) for the token list, keyed by lowercase address. Native MON has no entry — use the WMON address for its price.

```typescript
const markets = await nt.getTokenMarkets();
const usdc = markets["0x754704bc059f8c67012fed69bc8a327a5aafb603"];
console.log(usdc?.priceUsd, usdc?.change24h);
```

### `nt.getHealth()`

System health check.

## Supported DEXs

Uniswap V4, Uniswap V3, PancakeSwap V3, Capricorn, Atlantis, Kuru, LFJ, Nad.fun (bonding curve)

## Chain

Monad Mainnet (Chain ID: 143)

## License

MIT
