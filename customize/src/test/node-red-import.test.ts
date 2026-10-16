import { describe, expect, it } from "vitest";
import {
  analyzeFlow,
  applyPlacement,
  attachToSpot,
  groupByContainer,
  parseNodeRedPaste,
  reidNodes,
  removeNodes,
  type Node,
} from "@/lib/node-red-import";

const n = (id: string, type: string, extra: Record<string, unknown> = {}) => ({ id, type, ...extra }) as Node;

/** A typical editor export: tab + inject → function → mqtt out (+ broker config). */
const exportFlow = (): Node[] => [
  n("t1", "tab", { label: "ERP sync" }),
  n("broker", "mqtt-broker", { broker: "localhost" }),
  n("inj", "inject", { z: "t1", wires: [["fn"]] }),
  n("fn", "function", { z: "t1", name: "shape", func: "return msg;", wires: [["out"]] }),
  n("out", "mqtt out", { z: "t1", broker: "broker", wires: [] }),
];

let seq = 0;
const mint = () => `new${++seq}`;

describe("parseNodeRedPaste", () => {
  it("accepts an array, a v2 {rev, flows}, a {nodes} snippet and a single node", () => {
    const arr = JSON.stringify(exportFlow());
    for (const text of [arr, JSON.stringify({ rev: "x", flows: exportFlow() }), JSON.stringify({ nodes: exportFlow() })]) {
      const r = parseNodeRedPaste(text);
      expect("nodes" in r && r.nodes.length).toBe(5);
    }
    const one = parseNodeRedPaste(JSON.stringify(n("d", "debug", { z: "t" })));
    expect("nodes" in one && one.nodes[0].id).toBe("d");
  });
  it("rejects bad JSON, id-less nodes and duplicate ids with a named reason", () => {
    expect(parseNodeRedPaste("{nope")).toHaveProperty("error");
    expect(parseNodeRedPaste('[{"type":"debug"}]')).toMatchObject({ error: expect.stringMatching(/id/) });
    expect(parseNodeRedPaste('[{"id":"a","type":"x"},{"id":"a","type":"y"}]')).toMatchObject({
      error: expect.stringMatching(/Duplicate/),
    });
  });
});

describe("analyzeFlow", () => {
  it("counts, finds entry/exit nodes and collisions", () => {
    const a = analyzeFlow(exportFlow(), [n("fn", "debug")], "cpack");
    expect(a.total).toBe(5);
    expect(a.flowNodes).toBe(3);
    expect(a.configNodes).toBe(1);
    expect(a.tabs.map((t) => t.id)).toEqual(["t1"]);
    expect(a.entries).toEqual([]); // inject is a source, fn/out have inputs
    expect(a.exits.map((e) => e.id)).toEqual([]); // out has no outputs to leave open
    expect(a.collisions).toEqual(["fn"]);
  });
  it("mirrors the server ADR-0009 function bounds", () => {
    const bad = [
      n("a", "function", { z: "t", func: "const r = await fetch('http://x');" }),
      n("b", "function", { z: "t", func: "eval('1')" }),
      n("c", "function", { z: "t", func: Array(201).fill("x;").join("\n") }),
    ];
    const errs = analyzeFlow(bad, [], "cpack").findings.filter((f) => f.level === "error").map((f) => f.nodeId);
    expect(errs).toEqual(["a", "b", "c"]);
  });
  it("flags wires to nodes missing from the paste and ids in the generator namespace", () => {
    const a = analyzeFlow([n("cpack_x", "debug", { z: "t", wires: [["ghost"]] })], [], "cpack");
    expect(a.findings.some((f) => /ghost/.test(f.message))).toBe(true);
    expect(a.collisions).toEqual(["cpack_x"]);
  });
});

describe("reidNodes", () => {
  it("rewrites ids and every reference consistently, but never user code", () => {
    seq = 0;
    const flow = [
      ...exportFlow(),
      n("sf", "subflow", { name: "scale", in: [{ wires: [{ id: "sf_fn" }] }] }),
      n("sf_fn", "function", { z: "sf", func: "// mentions fn and broker\nreturn msg;" }),
      n("inst", "subflow:sf", { z: "t1", g: "grp" }),
      n("grp", "group", { z: "t1", nodes: ["inst"] }),
    ];
    const out = reidNodes(flow, mint);
    const byOld = new Map(flow.map((f, i) => [f.id, out[i]]));
    const idOf = (old: string) => byOld.get(old)!.id;
    expect(new Set(out.map((o) => o.id)).size).toBe(flow.length);
    expect(byOld.get("inj")!.wires).toEqual([[idOf("fn")]]);
    expect(byOld.get("fn")!.z).toBe(idOf("t1"));
    expect(byOld.get("out")!.broker).toBe(idOf("broker")); // config reference
    expect(byOld.get("inst")!.type).toBe(`subflow:${idOf("sf")}`);
    expect(byOld.get("inst")!.g).toBe(idOf("grp"));
    expect(byOld.get("grp")!.nodes).toEqual([idOf("inst")]);
    expect(byOld.get("sf")!.in).toEqual([{ wires: [{ id: idOf("sf_fn") }] }]);
    expect(byOld.get("sf_fn")!.func).toBe("// mentions fn and broker\nreturn msg;");
  });
});

describe("placement + spots", () => {
  it("customizations-tab placement drops tab nodes, keeps subflows", () => {
    const out = applyPlacement([...exportFlow(), n("sf", "subflow")], "customizations-tab");
    expect(out.map((x) => x.type)).not.toContain("tab");
    expect(out.map((x) => x.id)).toContain("sf");
  });
  it("tap: adds a link in subscribed to the spot, wired into the chosen entry nodes", () => {
    seq = 0;
    const out = attachToSpot(exportFlow(), "tags", "cpack", ["fn"], mint);
    const link = out.find((x) => x.type === "link in")!;
    expect(link).toMatchObject({ links: ["cpack_spot_tags"], wires: [["fn"]], z: "t1" });
  });
  it("publish: adds a link out to the entry spot, fed from the chosen exit nodes", () => {
    seq = 0;
    const out = attachToSpot(exportFlow(), "publish", "cpack", ["fn"], mint);
    const link = out.find((x) => x.type === "link out")!;
    expect(link).toMatchObject({ links: ["cpack_spot_publish"], mode: "link" });
    expect(out.find((x) => x.id === "fn")!.wires).toEqual([["out", link.id]]);
  });
  it("rejects an unknown spot or an empty target list", () => {
    expect(() => attachToSpot(exportFlow(), "nope", "cpack", ["fn"])).toThrow(/Unknown spot/);
    expect(() => attachToSpot(exportFlow(), "tags", "cpack", [])).toThrow(/at least one/);
  });
});

describe("groupByContainer + removeNodes", () => {
  it("groups by declared tab/subflow, the shared cust tab, and config", () => {
    const g = groupByContainer([...exportFlow(), n("loose", "debug", { z: "elsewhere" })], "cpack");
    expect(g.map((x) => x.label).sort()).toEqual(["Config nodes (shared)", "Customizations tab", "Tab · ERP sync"]);
  });
  it("removing a tab removes its nodes and scrubs dangling wires", () => {
    const flow = [...exportFlow(), n("keep", "debug", { z: "other", wires: [["fn"]] })];
    const out = removeNodes(flow, new Set(["t1"]));
    expect(out.map((x) => x.id).sort()).toEqual(["broker", "keep"]);
    expect(out.find((x) => x.id === "keep")!.wires).toEqual([[]]);
  });
});
