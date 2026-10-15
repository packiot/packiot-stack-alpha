import { describe, expect, it } from "vitest";
import { parseMirrorStatus } from "@/api/mirror-status";

describe("parseMirrorStatus (ADR-0064)", () => {
  it("a mirror carries the message and the production link", () => {
    const s = parseMirrorStatus({ mirror: true, idEnterprise: 5, productionUrl: "https://front.prod.packiot.app", message: "m" });
    expect(s).toEqual({ mirror: true, idEnterprise: 5, productionUrl: "https://front.prod.packiot.app", message: "m" });
  });
  it("anything else is not a mirror (older edge-api, garbage)", () => {
    expect(parseMirrorStatus({ mirror: false }).mirror).toBe(false);
    expect(parseMirrorStatus(undefined).mirror).toBe(false);
    expect(parseMirrorStatus("<html>").mirror).toBe(false);
  });
  it("a mirror without a message still explains itself", () => {
    expect(parseMirrorStatus({ mirror: true }).message).toMatch(/read-only mirror of production/);
  });
});
