import type {
  QuoteParams,
  QuoteResponse,
  SwapParams,
  SwapResponse,
  Token,
  TokenMarket,
  HealthResponse,
} from "./types";

/** Default public API endpoint — defined once, referenced everywhere. */
export const DEFAULT_BASE_URL = "https://api.nullterminal.xyz";

/** Default request timeout in milliseconds. */
const DEFAULT_TIMEOUT_MS = 10_000;

/** Thrown when the API returns a non-2xx response. Carries status + body. */
export class NullTerminalApiError extends Error {
  readonly status: number;
  readonly body: unknown;
  constructor(status: number, message: string, body: unknown) {
    super(message);
    this.name = "NullTerminalApiError";
    this.status = status;
    this.body = body;
  }
}

export interface NullTerminalConfig {
  /** API base URL (default: https://api.nullterminal.xyz) */
  baseUrl?: string;
  /** API key for higher rate limits */
  apiKey?: string;
  /** Per-request timeout in ms (default: 10000) */
  timeoutMs?: number;
}

export class NullTerminal {
  private baseUrl: string;
  private headers: Record<string, string>;
  private timeoutMs: number;

  constructor(config?: NullTerminalConfig) {
    this.baseUrl = config?.baseUrl || DEFAULT_BASE_URL;
    this.timeoutMs = config?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.headers = { "Content-Type": "application/json" };
    if (config?.apiKey) {
      this.headers["X-API-Key"] = config.apiKey;
    }
  }

  /**
   * Get the best swap quote across all DEXs.
   *
   * Slippage MUST be set here via `slippageBps` — it is baked into the
   * returned quote's `otherAmountThreshold` (minOut). buildSwap does NOT
   * tighten slippage; it only encodes the already-quoted threshold.
   *
   * @example
   * ```ts
   * const quote = await nt.getQuote({
   *   inputMint: "0x0000000000000000000000000000000000000000", // MON
   *   outputMint: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", // USDC
   *   amount: (1000n * 10n ** 18n).toString(),
   *   slippageBps: 50, // 0.5% — set slippage at QUOTE time
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
   * Note: slippage cannot be changed here — minOut is taken from the quote's
   * `otherAmountThreshold` (set at QUOTE time via getQuote's slippageBps).
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
        usePermit2: params.usePermit2,
      }),
    });
  }

  /** Get the full curated token list with logos, verified flag, and liquidity. */
  async getTokens(): Promise<Token[]> {
    const data = await this.fetch<{ tokens: Token[] }>("/v1/tokens");
    return data.tokens;
  }

  /**
   * Discover swap-ready tokens by symbol or name that are NOT in the curated list (on-chain search).
   * Returns logo-gated, on-chain-decimals tokens flagged `verified: false`.
   */
  async searchTokens(query: string): Promise<Token[]> {
    const data = await this.fetch<{ tokens: Token[] }>(
      `/v1/tokens/search?q=${encodeURIComponent(query)}`
    );
    return data.tokens;
  }

  /**
   * Market data (price / 24h change / 24h volume) for the token list, keyed by lowercase address.
   * Native MON has no entry — use the WMON address for its price.
   */
  async getTokenMarkets(): Promise<Record<string, TokenMarket>> {
    const data = await this.fetch<{ market: Record<string, TokenMarket> }>(
      "/v1/tokens/market"
    );
    return data.market || {};
  }

  /** System health check. */
  async getHealth(): Promise<HealthResponse> {
    return this.fetch("/v1/health");
  }

  private async fetch<T = any>(
    path: string,
    options?: RequestInit
  ): Promise<T> {
    // Abort the request if it exceeds the configured timeout so callers
    // are not left hanging on a slow/unreachable API.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    let res: Response;
    try {
      res = await globalThis.fetch(`${this.baseUrl}${path}`, {
        ...options,
        headers: { ...this.headers, ...options?.headers },
        signal: controller.signal,
      });
    } catch (err) {
      if (controller.signal.aborted) {
        throw new Error(`Request timed out after ${this.timeoutMs}ms: ${path}`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      const body = await res.json().catch(() => ({ message: res.statusText }));
      const message =
        (body && typeof body === "object" && "message" in body
          ? (body as { message?: string }).message
          : undefined) || `API error: ${res.status}`;
      throw new NullTerminalApiError(res.status, message, body);
    }

    return res.json();
  }
}
