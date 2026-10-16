import type { ClientDescriptor, DescriptorDerived, DescriptorEquipment, SimulateSample } from "@/api/onboarding";
import { localSegment } from "@/lib/derive-rules";

/**
 * The Calculations page's pure core. A calculation = "a new value, computed from
 * counters you already have, attached to one machine or line". Users pick from
 * lists; this file turns those picks into the rule the data collector runs, and
 * turns stored rules back into plain sentences. No React, no I/O.
 *
 * Path rules (must match the generator, clientdescriptor.resolveDerived):
 *  - a value from the SAME equipment is written relative: /Admin/<counter>/{idx}/Unit
 *  - a value from ANOTHER machine is its full topic: <topic>/Admin/<counter>/<its index>/Unit
 */

export interface Counter {
  leaf: string;
  label: string;
  hint: string;
}

/** The counters a factory machine reports, in plain words. */
export const COUNTERS: Counter[] = [
  { leaf: "ProdProcessedCount", label: "Good parts made", hint: "net count" },
  { leaf: "ProdConsumedCount", label: "Everything that went in", hint: "gross count" },
  { leaf: "ProdDefectiveCount", label: "Scrap / rejects", hint: "defective count" },
];

/** What a calculation's result can be. These are the numbers OEE understands. */
export const RESULTS: { leaf: string; label: string; example: string }[] = [
  { leaf: "ProdDefectiveCount", label: "Scrap / rejects", example: "what went in − good parts" },
  { leaf: "ProdConsumedCount", label: "Everything that went in", example: "machine A + machine B" },
  { leaf: "ProdProcessedCount", label: "Good parts made", example: "packs × 12" },
];

export const FORMULA_EXAMPLES = ["a - b", "a + b", "(a + b) * 12", "a / 12", "max(a, b)"];

export const counterLabel = (leaf: string) => COUNTERS.find((c) => c.leaf === leaf)?.label ?? leaf;

export interface Machine {
  id: number;
  topic: string;
  name: string;
  kind: "line" | "machine" | "sector";
  index?: number;
}

export function machinesOf(d: ClientDescriptor, names: Map<number, string>): Machine[] {
  return (d.equipment ?? [])
    .filter((e): e is DescriptorEquipment & { id_equipment: number } => e.id_equipment != null)
    .map((e) => ({
      id: e.id_equipment,
      topic: e.topic,
      name: names.get(e.id_equipment) || e.topic.split("/").pop() || `#${e.id_equipment}`,
      kind: e.tp_equipment === 3 ? "line" : e.tp_equipment === 2 ? "sector" : "machine",
      index: e.count_index?.value,
    }));
}

export interface Input {
  letter: string;
  machineId: number;
  counter: string;
}

/** The var path for one input, or a plain-language reason it can't be used. */
export function inputPath(target: Machine, source: Machine, counter: string): { path: string } | { error: string } {
  if (source.id === target.id) return { path: `/Admin/${counter}/{idx}/Unit` };
  if (source.index == null) {
    return { error: `${source.name} has no counter number yet, so it can't be used in a calculation. Confirm its counters in CS Admin first.` };
  }
  return { path: `${source.topic}/Admin/${counter}/${source.index}/Unit` };
}

/** Letters used in the formula must all be defined, and nothing else may appear. */
export function checkFormula(formula: string, letters: string[]): string | null {
  const f = formula.trim();
  if (!f) return "Write a formula, for example a - b.";
  const words = f.match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? [];
  const allowedFns = new Set(["max", "min", "abs", "round", "floor", "ceil"]);
  for (const w of words) {
    if (allowedFns.has(w)) continue;
    if (!letters.includes(w)) return `"${w}" isn't one of your values (${letters.join(", ") || "none yet"}).`;
  }
  if (!/^[\sA-Za-z0-9_+\-*/().,]+$/.test(f)) return "Use only numbers, your letters, + − × ÷ and brackets.";
  return null;
}

export function buildRule(result: string, formula: string, vars: Record<string, string>): DescriptorDerived {
  return { emit: [`/Admin/${result}/{idx}/Unit`], type: "double", expr: { expr: formula.trim(), vars } };
}

/** Turn a stored var path back into "<machine> · <counter>". */
export function describeInput(path: string, owner: Machine, machines: Machine[]): string {
  const m = path.match(/\/Admin\/([^/]+)\/[^/]+\/Unit$/);
  const counter = m ? counterLabel(m[1]) : path;
  if (path.startsWith("/")) return `${owner.name} · ${counter}`;
  const src = [...machines].sort((a, b) => b.topic.length - a.topic.length).find((x) => path.startsWith(`${x.topic}/`));
  return `${src?.name ?? "another machine"} · ${counter}`;
}

/** Plain sentence for a stored rule: "Scrap / rejects = a − b". */
export function describeRule(rule: DescriptorDerived): string {
  const m = rule.emit[0]?.match(/\/Admin\/([^/]+)\//);
  const what = m ? (RESULTS.find((r) => r.leaf === m[1])?.label ?? m[1]) : rule.emit[0];
  return `${what} = ${rule.expr?.expr ?? "(not a formula rule)"}`;
}

/** Build simulator samples from the numbers the user typed for each letter. */
export function samplesFor(
  target: Machine,
  inputs: Input[],
  values: Record<string, number>,
  machines: Machine[],
  prefix: string | undefined,
): SimulateSample[] {
  return inputs.map((inp, i) => {
    const src = machines.find((m) => m.id === inp.machineId) ?? target;
    const idx = src.index ?? 0;
    return {
      metric: `${localSegment(src.topic, prefix)}/Admin/${inp.counter}/${idx}/Unit`,
      value: values[inp.letter] ?? 0,
      ts_millis: 1000 + i,
    };
  });
}
