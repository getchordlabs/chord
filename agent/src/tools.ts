// Chord agent harness — library entry. The tools live in the API (hosted MCP, POST /v1/mcp): `listTools()` reads the
// current list, `runTool()` calls one and returns its JSON. Every data tool takes a `chain`; chord_chains says what each
// chain supports. Nothing here signs or sends: chord_swap_tx returns an UNSIGNED transaction for the caller's own wallet.
import { callTool, listTools } from "./remote.js";

export { endpoint, initialize, listTools, callTool, type RemoteTool, type ToolResult } from "./remote.js";

/** Call one tool and return its parsed answer `{ chain?, route, data }`. A tool-level error throws with the tool's message. */
export async function runTool<T = any>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const r = await callTool(name, args);
  const text = r.content?.find((c) => c.type === "text")?.text ?? "";
  if (r.isError) throw new Error(text || `${name} failed`);
  try { return JSON.parse(text) as T; } catch { return text as unknown as T; }
}

/** The tool list as OpenAI-style function definitions (the same content as GET /v1/mcp/tools.json). */
export async function toolManifest() {
  return (await listTools()).map((t) => ({ type: "function" as const, function: { name: t.name, description: t.description, parameters: t.inputSchema } }));
}
