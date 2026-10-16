import { useEffect, useMemo, useState } from "react";
import { ClipboardPaste, CornerDownRight, TriangleAlert } from "lucide-react";
import { toast } from "sonner";
import { Button, Card, Select, Textarea } from "@/components/ui";
import {
  analyzeFlow,
  applyPlacement,
  attachToSpot,
  parseNodeRedPaste,
  reidNodes,
  type Node,
  type Placement,
} from "@/lib/node-red-import";
import { READER_SPOTS } from "@/lib/node-red-spots";

interface Props {
  prefix: string;
  existing: Node[];
  onInsert: (nodes: Node[]) => void;
}

const nodeLabel = (n: Node) => `${typeof n.name === "string" && n.name ? n.name : n.type} · ${n.id}`;

/**
 * Paste any Node-RED export → see what it is → choose where it goes → insert it
 * into the (unsaved) customizations. Nothing reaches the descriptor until Save,
 * and nothing reaches the box until Plan → Apply.
 */
export function FlowInserter({ prefix, existing, onInsert }: Props) {
  const [text, setText] = useState("");
  const [freshIds, setFreshIds] = useState(false);
  const [placement, setPlacement] = useState<Placement>("customizations-tab");
  const [spot, setSpot] = useState("");
  const [targets, setTargets] = useState<string[]>([]);

  const parsed = useMemo(() => (text.trim() ? parseNodeRedPaste(text) : null), [text]);
  const nodes = parsed && "nodes" in parsed ? parsed.nodes : null;
  const analysis = useMemo(() => (nodes ? analyzeFlow(nodes, existing, prefix) : null), [nodes, existing, prefix]);
  const spotDef = READER_SPOTS.find((s) => s.key === spot);
  const flowNodes = useMemo(
    () => (nodes ?? []).filter((n) => typeof n.z === "string" && n.type !== "tab" && n.type !== "subflow"),
    [nodes],
  );

  // Collisions make "import as copy" mandatory; default the targets to the
  // analyzer's best guess whenever the spot or paste changes.
  useEffect(() => {
    if (analysis?.collisions.length) setFreshIds(true);
  }, [analysis?.collisions.length]);
  useEffect(() => {
    if (!analysis || !spotDef) return setTargets([]);
    const guess = spotDef.kind === "tap" ? analysis.entries : analysis.exits;
    setTargets(guess.slice(0, 1).map((n) => n.id));
  }, [analysis, spotDef]);

  const errors = analysis?.findings.filter((f) => f.level === "error") ?? [];
  const warnings = analysis?.findings.filter((f) => f.level === "warning") ?? [];
  const blockedByCollision = !!analysis?.collisions.length && !freshIds;
  const canInsert = !!nodes && errors.length === 0 && !blockedByCollision && (!spot || targets.length > 0);

  function insert() {
    if (!nodes) return;
    try {
      let out = applyPlacement(nodes, placement);
      let tgt = targets;
      if (freshIds) {
        // Re-id AFTER placement, then translate the chosen targets through the map.
        const reid = reidNodes(out);
        const map = new Map(out.map((n, i) => [n.id, reid[i].id]));
        tgt = targets.map((t) => map.get(t) ?? t);
        out = reid;
      }
      if (spot) out = attachToSpot(out, spot, prefix, tgt);
      onInsert(out);
      toast.success(`Inserted ${out.length} node(s) — Save to store them on the descriptor.`);
      setText("");
      setSpot("");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not insert");
    }
  }

  return (
    <Card className="mb-5 px-7 py-6">
      <div className="mb-1 flex items-center gap-2">
        <ClipboardPaste className="h-4 w-4 text-primary" />
        <span className="text-[15px] font-extrabold text-foreground">Insert a flow</span>
      </div>
      <p className="mb-3 max-w-[720px] text-[13px] text-muted-foreground">
        Paste a Node-RED export from anywhere (Export → Copy, a flows.json, a library snippet). Pick where it
        lands and, optionally, which point of the PLC reader it connects to.
      </p>
      <Textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        spellCheck={false}
        placeholder='[ { "id": "…", "type": "inject", … }, … ]'
        className="h-[180px] bg-chrome font-mono text-[12px] leading-[1.55] text-chrome-foreground"
      />

      {parsed && "error" in parsed && <p className="mt-2 text-[13px] text-danger">{parsed.error}</p>}

      {analysis && (
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <div className="text-[13px]">
            <p className="mb-1 font-bold text-foreground">What you pasted</p>
            <p className="text-muted-foreground">
              {analysis.total} node(s): {analysis.flowNodes} flow · {analysis.configNodes} config
              {analysis.tabs.length ? ` · ${analysis.tabs.length} tab(s)` : ""}
              {analysis.subflows.length ? ` · ${analysis.subflows.length} subflow(s)` : ""}
            </p>
            <p className="mt-1 font-mono text-[11px] text-muted-foreground">
              {analysis.byType.map(([t, c]) => `${t}×${c}`).join("  ")}
            </p>
            {[...errors, ...warnings].length > 0 && (
              <ul className="mt-2 space-y-1">
                {errors.map((f, i) => (
                  <li key={`e${i}`} className="flex gap-1.5 text-danger">
                    <TriangleAlert className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {f.message}
                  </li>
                ))}
                {warnings.map((f, i) => (
                  <li key={`w${i}`} className="flex gap-1.5 text-warning-strong">
                    <TriangleAlert className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {f.message}
                  </li>
                ))}
              </ul>
            )}
            {analysis.collisions.length > 0 && (
              <p className="mt-2 text-warning-strong">
                {analysis.collisions.length} id(s) already exist here or are reserved by the generator (
                <span className="font-mono">{analysis.collisions.slice(0, 3).join(", ")}</span>
                {analysis.collisions.length > 3 ? ", …" : ""}) — insert as a copy with fresh ids.
              </p>
            )}
          </div>

          <div className="space-y-3 text-[13px]">
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={freshIds} onChange={(e) => setFreshIds(e.target.checked)} />
              <span>
                Insert as a copy <span className="text-muted-foreground">(fresh ids, every wire/config reference rewritten)</span>
              </span>
            </label>
            <div>
              <p className="mb-1 font-semibold text-foreground">Lands on</p>
              <Select value={placement} onChange={(e) => setPlacement(e.target.value as Placement)}>
                <option value="customizations-tab">The customizations tab (shared)</option>
                <option value="own-tab" disabled={analysis.tabs.length === 0}>
                  Its own tab{analysis.tabs.length ? ` (${analysis.tabs.map((t) => String(t.label ?? t.id)).join(", ")})` : " — the paste has no tab"}
                </option>
              </Select>
            </div>
            <div>
              <p className="mb-1 font-semibold text-foreground">Connect to the PLC reader</p>
              <Select value={spot} onChange={(e) => setSpot(e.target.value)}>
                <option value="">Not connected (standalone)</option>
                {READER_SPOTS.map((s) => (
                  <option key={s.key} value={s.key}>
                    {s.kind === "tap" ? "Receive: " : "Send: "}
                    {s.label}
                  </option>
                ))}
              </Select>
              {spotDef && <p className="mt-1 text-[12px] text-muted-foreground">{spotDef.hint}</p>}
            </div>
            {spotDef && (
              <div>
                <p className="mb-1 font-semibold text-foreground">
                  {spotDef.kind === "tap" ? "Feed these nodes with it" : "Send from these nodes' first output"}
                </p>
                <div className="max-h-36 space-y-1 overflow-auto rounded-md border border-border p-2">
                  {flowNodes.map((n) => (
                    <label key={n.id} className="flex items-center gap-2 font-mono text-[12px]">
                      <input
                        type="checkbox"
                        checked={targets.includes(n.id)}
                        onChange={(e) =>
                          setTargets((t) => (e.target.checked ? [...t, n.id] : t.filter((x) => x !== n.id)))
                        }
                      />
                      <CornerDownRight className="h-3 w-3 text-muted-foreground" />
                      {nodeLabel(n)}
                    </label>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      <div className="mt-4 flex items-center justify-end gap-3">
        {blockedByCollision && <span className="text-[12px] text-warning-strong">Tick "Insert as a copy" to resolve id collisions.</span>}
        <Button onClick={insert} disabled={!canInsert}>
          Insert
        </Button>
      </div>
    </Card>
  );
}
