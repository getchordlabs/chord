# @nullterminal/sdk

DEX aggregator SDK for Monad. Optimal swap routes across 9 DEXs, split orders, single transaction.

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
| `slippageBps` | number | No | Override slippage |

Returns `{ transaction: { to, data, value, gasLimit, chainId } }`

### `nt.getTokens()`

Returns the full token list with logos and metadata.

### `nt.getHealth()`

System health check.

## Supported DEXs

Uniswap V4, Uniswap V3, PancakeSwap V3, Capricorn, OctoSwap, Atlantis, Kuru, LFJ, Uniswap V2

## Chain

Monad Mainnet (Chain ID: 143)

## License

MIT
