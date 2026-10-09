import { describe, expect, it } from "vitest";
import { localSegment, relativizeVars, ruleInputs, buildDeriveRule } from "@/lib/derive-rules";

// The live staging probe (2026-09-29, SBXCPACK CER400): a full-path var resolved to
// seg+seg+leaf and the rule silently never fired; relative vars emitted scrap=30.
const SEG = "/CELULA1/CER400/CER400";

describe("derive var paths", () => {
  it("localSegment strips the tenant canonical prefix", () => {
    expect(localSegment("SBXCPACK/SC/CELULA1/CER400/CER400", "SBXCPACK/SC")).toBe(SEG);
  });
  it("strips the equipment's own segment from a full-path var", () => {
    const r = relativizeVars({ gross: `${SEG}/Admin/ProdProcessedCount/107/Unit`, net: "/Admin/ProdCount/{idx}/Unit" }, SEG);
    expect(r).toEqual({
      vars: { gross: "/Admin/ProdProcessedCount/107/Unit", net: "/Admin/ProdCount/{idx}/Unit" },
      stripped: ["gross"],
    });
  });
  it("rejects a var that points at another equipment", () => {
    expect(relativizeVars({ x: "/CELULA1/OTHER/OTHER/Admin/ProdCount/1/Unit" }, SEG)).toHaveProperty("error");
  });
  it("keeps reader-published /Derive sensors", () => {
    expect(relativizeVars({ s: "/Derive/S1" }, SEG)).toEqual({ vars: { s: "/Derive/S1" }, stripped: [] });
  });
  it("ruleInputs lists the exact metrics the rule waits for", () => {
    const rule = buildDeriveRule("scrap", "gross - net", { gross: "/Admin/ProdProcessedCount/{idx}/Unit" });
    expect(ruleInputs(rule, SEG, 107)).toEqual([`${SEG}/Admin/ProdProcessedCount/107/Unit`]);
  });
});
