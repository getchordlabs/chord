export interface Token {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  logoURI?: string;
  tags?: string[];
}

export interface QuoteResponse {
  inputMint: string;
  outputMint: string;
  inputAmount: string;
  outputAmount: string;
  otherAmountThreshold: string;
  priceImpactPct: string;
  routePlan: RoutePlanStep[];
  gasEstimate: string;
  gasCostUSD: string;
  blockNumber: number;
  timeTaken: number;
}

export interface RoutePlanStep {
  percent: number;
  swapInfo: SwapInfo;
}

export interface SwapInfo {
  dex: string;
  pool: string;
  inputMint: string;
  outputMint: string;
  inputAmount: string;
  outputAmount: string;
  feeAmount?: string;
  feeMint?: string;
  adapter: string;
  extraData: string;
}

export interface SwapResponse {
  transaction: UnsignedTransaction;
  lastValidBlockHeight: number;
}

export interface UnsignedTransaction {
  to: string;
  data: string;
  value: string;
  gasLimit: string;
  chainId: number;
}

export interface QuoteParams {
  inputMint: string;
  outputMint: string;
  amount: string;
  slippageBps?: number;
}

// Aligned with shared SwapRequest. Note: slippage is NOT set here — it is
// baked into quoteResponse.otherAmountThreshold at QUOTE time (see getQuote).
export interface SwapParams {
  quoteResponse: QuoteResponse;
  userPublicKey: string;
  wrapUnwrapMON?: boolean;
  feeAccount?: string; // referral address
  usePermit2?: boolean;
}

export interface HealthResponse {
  status: string;
  version: string;
  uptime: number;
  engine: { status: string; latencyMs: number };
  redis: { status: string };
  poolCount: number;
  lastSyncBlock: number;
}
