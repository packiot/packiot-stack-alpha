import { describe, expect, it } from "vitest";
import { buildRule, checkFormula, describeInput, describeRule, inputPath, samplesFor, type Machine } from "@/lib/calc-builder";

const line: Machine = { id: 100, topic: "BIS/SP/LINHAS/L01", name: "Line 01", kind: "line", index: 100 };
const s3: Machine = { id: 103, topic: "BIS/SP/LINHAS/L01/S3", name: "S3", kind: "machine", index: 103 };
const s9: Machine = { id: 109, topic: "BIS/SP/LINHAS/L01/S9", name: "S9", kind: "machine" };
const all = [line, s3, s9];

describe("calc-builder", () => {
  it("same equipment → relative path; other machine → its full topic + its counter number", () => {
    expect(inputPath(line, line, "ProdConsumedCount")).toEqual({ path: "/Admin/ProdConsumedCount/{idx}/Unit" });
    expect(inputPath(line, s3, "ProdProcessedCount")).toEqual({ path: "BIS/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit" });
    expect(inputPath(line, s9, "ProdProcessedCount")).toHaveProperty("error");
  });
  it("formula check names the unknown letter in plain words", () => {
    expect(checkFormula("a - b", ["a", "b"])).toBeNull();
    expect(checkFormula("max(a, b) * 12", ["a", "b"])).toBeNull();
    expect(checkFormula("a - c", ["a", "b"])).toMatch(/"c" isn't one of your values/);
    expect(checkFormula("", ["a"])).toMatch(/Write a formula/);
  });
  it("describes stored rules and inputs back in plain words (longest topic wins)", () => {
    const rule = buildRule("ProdDefectiveCount", "a - b", {
      a: "/Admin/ProdConsumedCount/{idx}/Unit",
      b: "BIS/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit",
    });
    expect(describeRule(rule)).toBe("Scrap / rejects = a - b");
    expect(describeInput(rule.expr!.vars.a, line, all)).toBe("Line 01 · Everything that went in");
    expect(describeInput(rule.expr!.vars.b, line, all)).toBe("S3 · Good parts made");
  });
  it("builds simulator samples exactly as the data collector will see the inputs", () => {
    const s = samplesFor(line, [{ letter: "a", machineId: 103, counter: "ProdProcessedCount" }], { a: 40 }, all, "BIS/SP");
    expect(s).toEqual([{ metric: "/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit", value: 40, ts_millis: 1000 }]);
  });
});
