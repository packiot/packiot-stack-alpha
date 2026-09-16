/**
 * ADR-0058 Tier-1 op-builder — the PURE core of authoring a declarative `expr`
 * derive rule (scrap = gross − net, merge two PLCs into one tag, …).
 *
 * These helpers are shared by BOTH surfaces that author derive rules — the
 * onboarding wizard's Review step and the standalone `/app/customizations`
 * editor — so the two never drift. No React, no I/O: build a rule, add/remove it
 * on a descriptor immutably, and parse the two free-text inputs (vars + samples).
 */
import type {
  ClientDescriptor,
  DescriptorDerived,
  SimulateSample,
} from "@/api/onboarding";

export type DeriveRole = "scrap" | "gross" | "net";

/** The canonical count leaf each role publishes (the agent synthesizes it). */
export const ROLE_LEAF: Record<DeriveRole, string> = {
  scrap: "ProdDefectiveCount",
  gross: "ProdConsumedCount",
  net: "ProdProcessedCount",
};

/** Human label for the role picker. */
export const ROLE_LABEL: Record<DeriveRole, string> = {
  scrap: "Scrap — ProdDefectiveCount",
  gross: "Gross — ProdConsumedCount",
  net: "Net — ProdProcessedCount",
};

/**
 * Parse the vars textarea: one `name = /arriving/suffix` per line. `name` is the
 * short identifier used in the expression; the suffix is the arriving metric it
 * binds to. Returns the map or a `{ error }` describing the first bad line.
 */
export function parseVarLines(
  text: string,
): Record<string, string> | { error: string } {
  const out: Record<string, string> = {};
  for (const [i, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (line === "") continue;
    const eq = line.indexOf("=");
    if (eq < 0) return { error: `line ${i + 1}: expected "name = /suffix"` };
    const name = line.slice(0, eq).trim();
    const suffix = line.slice(eq + 1).trim();
    if (name === "" || suffix === "")
      return { error: `line ${i + 1}: empty name or suffix` };
    out[name] = suffix;
  }
  return out;
}

/** Build the DescriptorDerived `expr` rule from op-builder inputs. */
export function buildDeriveRule(
  role: DeriveRole,
  expr: string,
  vars: Record<string, string>,
): DescriptorDerived {
  return {
    emit: [`/Admin/${ROLE_LEAF[role]}/{idx}/Unit`],
    type: "double",
    expr: { expr, vars },
  };
}

/**
 * Immutably append a derive rule to `descriptor.equipment[id].derived`, creating
 * the equipment entry if the descriptor doesn't carry it yet. Never mutates the
 * input (React-state safe).
 */
export function addDeriveRule(
  descriptor: ClientDescriptor,
  idEquipment: number,
  topic: string,
  tpEquipment: number | undefined,
  rule: DescriptorDerived,
): ClientDescriptor {
  const eqs = [...(descriptor.equipment ?? [])];
  const i = eqs.findIndex((e) => e.id_equipment === idEquipment);
  if (i >= 0) {
    const cur = Array.isArray(eqs[i].derived)
      ? [...(eqs[i].derived as DescriptorDerived[])]
      : [];
    eqs[i] = { ...eqs[i], derived: [...cur, rule] };
  } else {
    eqs.push({
      topic,
      id_equipment: idEquipment,
      tp_equipment: tpEquipment,
      derived: [rule],
    });
  }
  return { ...descriptor, equipment: eqs };
}

/**
 * Immutably remove the derive rule at `idx` from equipment `idEquipment`. Drops
 * the `derived` array entirely when it becomes empty (keeps the descriptor tidy).
 */
export function removeDeriveRule(
  descriptor: ClientDescriptor,
  idEquipment: number,
  idx: number,
): ClientDescriptor {
  const eqs = [...(descriptor.equipment ?? [])];
  const i = eqs.findIndex((e) => e.id_equipment === idEquipment);
  if (i < 0) return descriptor;
  const cur = [...((eqs[i].derived as DescriptorDerived[]) ?? [])];
  cur.splice(idx, 1);
  eqs[i] = { ...eqs[i], derived: cur.length ? cur : undefined };
  return { ...descriptor, equipment: eqs };
}

/** One flattened authored rule (for the list + remove). */
export interface DeriveRuleRow {
  id: number;
  topic: string;
  idx: number;
  rule: DescriptorDerived;
}

/**
 * Flatten every authored derive rule across the descriptor's equipment. `topicOf`
 * lets a caller substitute a nicer topic (e.g. from the live topology) than the
 * one stored on the descriptor entry.
 */
export function listDeriveRules(
  descriptor: ClientDescriptor,
  topicOf?: (id: number) => string | undefined,
): DeriveRuleRow[] {
  const rows: DeriveRuleRow[] = [];
  for (const e of descriptor.equipment ?? []) {
    if (e.id_equipment == null || !Array.isArray(e.derived)) continue;
    e.derived.forEach((rule, idx) =>
      rows.push({
        id: e.id_equipment!,
        topic: topicOf?.(e.id_equipment!) ?? e.topic ?? "",
        idx,
        rule,
      }),
    );
  }
  return rows;
}

/**
 * Parse the simulate samples textarea (a JSON array of `{metric,value,ts_millis}`).
 * `ts_millis` defaults to the row index so a bare `[{metric,value}]` still orders.
 */
export function parseSamples(
  text: string,
): SimulateSample[] | { error: string } {
  const t = text.trim();
  if (t === "") return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(t);
  } catch (e) {
    return { error: e instanceof Error ? e.message : "invalid JSON" };
  }
  if (!Array.isArray(parsed)) return { error: "expected a JSON array of tags" };
  const out: SimulateSample[] = [];
  for (const [i, row] of parsed.entries()) {
    const r = row as Record<string, unknown>;
    if (typeof r?.metric !== "string" || r.metric === "")
      return { error: `sample[${i}].metric must be a non-empty string` };
    if (typeof r?.value !== "number")
      return { error: `sample[${i}].value must be a number` };
    out.push({
      metric: r.metric,
      value: r.value,
      ts_millis: typeof r.ts_millis === "number" ? r.ts_millis : i + 1,
    });
  }
  return out;
}
