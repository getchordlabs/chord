// Tiny zod → JSON Schema for the shapes this harness uses (objects of strings, numbers, enums,
// defaults, descriptions, `any`). Keeps the package free of a second schema dependency.
import { z } from "zod";

export function zodToJsonSchema(schema: z.ZodTypeAny): Record<string, unknown> {
  const def: any = (schema as any)._def;
  const desc = schema.description ? { description: schema.description } : {};
  switch (def.typeName) {
    case "ZodObject": {
      const shape = def.shape(); const properties: Record<string, unknown> = {}; const required: string[] = [];
      for (const [k, v] of Object.entries(shape)) {
        properties[k] = zodToJsonSchema(v as z.ZodTypeAny);
        const inner: any = (v as any)._def;
        if (inner.typeName !== "ZodDefault" && inner.typeName !== "ZodOptional") required.push(k);
      }
      return { type: "object", properties, ...(required.length ? { required } : {}), additionalProperties: false, ...desc };
    }
    case "ZodString": return { type: "string", ...desc };
    case "ZodNumber": return { type: def.checks?.some((c: any) => c.kind === "int") ? "integer" : "number", ...desc };
    case "ZodBoolean": return { type: "boolean", ...desc };
    case "ZodEnum": return { type: "string", enum: def.values, ...desc };
    case "ZodDefault": return { ...zodToJsonSchema(def.innerType), default: def.defaultValue(), ...desc };
    case "ZodOptional": return { ...zodToJsonSchema(def.innerType), ...desc };
    case "ZodAny": return { ...desc };
    default: return { ...desc };
  }
}
