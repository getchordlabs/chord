import type {
  QuoteParams,
  QuoteResponse,
  SwapParams,
  SwapResponse,
  Token,
  HealthResponse,
} from "./types";

export interface NullTerminalConfig {
  /** API base URL (default: https://api.nullterminal.xyz) */
  baseUrl?: string;
  /** API key for higher rate limits */
  apiKey?: string;
}

export class NullTerminal {
  private baseUrl: string;
  private headers: Record<string, string>;

  constructor(config?: NullTerminalConfig) {
    this.baseUrl = config?.baseUrl || "https://api.nullterminal.xyz";
    this.headers = { "Content-Type": "application/json" };
    if (config?.apiKey) {
      this.headers["X-API-Key"] = config.apiKey;
    }
  }

  /**
   * Get the best swap quote across all DEXs.
   *
   * @example
   * ```ts
   * const quote = await nt.getQuote({
   *   inputMint: "0x0000000000000000000000000000000000000000", // MON
   *   outputMint: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", // USDC
   *   amount: (1000n * 10n ** 18n).toString(),
   * });
   * ```
   */
  async getQuote(params: QuoteParams): Promise<QuoteResponse> {
    const search = new URLSearchParams({
      inputMint: params.inputMint,
      outputMint: params.outputMint,
      amount: params.amount,
      ...(params.slippageBps !== undefined
        ? { slippageBps: String(params.slippageBps) }
        : {}),
    });
    return this.fetch(`/v1/quote?${search}`);
  }

  /**
   * Build an unsigned swap transaction from a quote.
   * Sign with any wallet library (ethers, viem, wagmi).
   *
   * @example
   * ```ts
   * const { transaction } = await nt.buildSwap({
   *   quoteResponse: quote,
   *   userPublicKey: "0x...",
   * });
   * await wallet.sendTransaction(transaction);
   * ```
   */
  async buildSwap(params: SwapParams): Promise<SwapResponse> {
    return this.fetch("/v1/swap", {
      method: "POST",
      body: JSON.stringify({
        quoteResponse: params.quoteResponse,
        userPublicKey: params.userPublicKey,
        wrapUnwrapMON: params.wrapUnwrapMON ?? true,
        feeAccount: params.feeAccount,
        slippageBps: params.slippageBps,
      }),
    });
  }

  /** Get the full token list with logos and metadata. */
  async getTokens(): Promise<Token[]> {
    const data = await this.fetch<{ tokens: Token[] }>("/v1/tokens");
    return data.tokens;
  }

  /** System health check. */
  async getHealth(): Promise<HealthResponse> {
    return this.fetch("/v1/health");
  }

  private async fetch<T = any>(
    path: string,
    options?: RequestInit
  ): Promise<T> {
    const res = await globalThis.fetch(`${this.baseUrl}${path}`, {
      ...options,
      headers: { ...this.headers, ...options?.headers },
    });

    if (!res.ok) {
      const error = await res.json().catch(() => ({ message: res.statusText }));
      throw new Error(error.message || `API error: ${res.status}`);
    }

    return res.json();
  }
}
