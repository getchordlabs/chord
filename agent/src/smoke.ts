// Calls the hosted tools once per chain against the live API and prints one line each — the check to run before
// publishing or after an API change. `pnpm smoke`. Exits 1 when any line fails.
import { listTools, runTool } from "./tools.js";

let failed = 0;
const line = (name: string, v: unknown) => console.log(name.padEnd(28), JSON.stringify(v).slice(0, 150));
async function check(label: string, fn: () => Promise<unknown>) {
  try { line(label, await fn()); } catch (e) { failed++; line(label, { FAILED: (e as Error).message.slice(0, 120) }); }
}

const tools = await listTools();
line("tools", tools.map((t) => t.name).length);
const dir: any = await runTool("chord_chains");
const chains: { key: string; has: string[]; anchors: { address: string; stableUsd: number | null; decimals: number }[]; wrappedNative: string }[] = dir.chains;
line("chord_chains", chains.map((c) => `${c.key}:${c.has.length}`));
await check("chord_status", async () => ((await runTool("chord_status")) as any).data.chains.map((c: any) => [c.key, c.quotes?.engine ?? "-", c.data?.ageSec ?? "-"]));

for (const c of chains) {
  if (c.has.includes("overview")) await check(`${c.key} overview`, async () => Object.keys(((await runTool("chord_overview", { chain: c.key })) as any).data).slice(0, 5));
  if (c.has.includes("tokens")) await check(`${c.key} tokens`, async () => { const d = ((await runTool("chord_tokens", { chain: c.key, limit: 3 })) as any).data; return Array.isArray(d) ? d.length : Object.keys(d).slice(0, 4); });
  const stable = c.anchors.find((a) => a.stableUsd === 1);
  if (c.has.includes("quote") && stable && stable.address !== c.wrappedNative) {
    await check(`${c.key} quote`, async () => {
      const q = ((await runTool("chord_quote", { chain: c.key, tokenIn: stable.address, tokenOut: c.wrappedNative, amount: String(10n * 10n ** BigInt(stable.decimals)) })) as any).data;
      return { provider: q.provider, out: q.amountOut, quoteId: !!q.quoteId };
    });
  }
}
console.log(failed ? `${failed} failed` : "ok");
process.exit(failed ? 1 : 0);
