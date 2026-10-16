import { useMemo, useState } from "react";
import { Braces, Layers, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button, Card, Textarea } from "@/components/ui";
import { groupByContainer, parseNodeRedPaste, removeNodes, type Node } from "@/lib/node-red-import";

interface Props {
  prefix: string;
  nodes: Node[];
  onChange: (nodes: Node[]) => void;
}

const spotLinks = (n: Node, prefix: string) =>
  ((Array.isArray(n.links) ? n.links : []) as string[]).filter((l) => l.startsWith(`${prefix}_spot_`));

/** The customizations on the descriptor, grouped by where they render. */
export function CustomizationList({ prefix, nodes, onChange }: Props) {
  const groups = useMemo(() => groupByContainer(nodes, prefix), [nodes, prefix]);
  const [raw, setRaw] = useState<string | null>(null);

  function drop(ids: string[]) {
    onChange(removeNodes(nodes, new Set(ids)));
  }

  function applyRaw() {
    if (raw == null) return;
    if (raw.trim() === "") {
      onChange([]);
      setRaw(null);
      return;
    }
    const r = parseNodeRedPaste(raw);
    if ("error" in r) return toast.error(r.error);
    onChange(r.nodes);
    setRaw(null);
  }

  return (
    <Card className="mb-5 px-7 py-6">
      <div className="mb-3 flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Layers className="h-4 w-4 text-primary" />
          <span className="text-[15px] font-extrabold text-foreground">Customizations on the descriptor</span>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => setRaw(raw == null ? JSON.stringify(nodes, null, 2) : null)}
        >
          <Braces className="h-3.5 w-3.5" /> {raw == null ? "Edit JSON" : "Close JSON"}
        </Button>
      </div>

      {raw != null ? (
        <>
          <Textarea
            value={raw}
            onChange={(e) => setRaw(e.target.value)}
            spellCheck={false}
            className="h-[300px] bg-chrome font-mono text-[12px] text-chrome-foreground"
          />
          <div className="mt-2 flex justify-end">
            <Button size="sm" onClick={applyRaw}>
              Use this JSON
            </Button>
          </div>
        </>
      ) : groups.length === 0 ? (
        <p className="text-[13px] text-muted-foreground">None yet — insert a flow above.</p>
      ) : (
        <div className="space-y-4">
          {groups.map((g) => (
            <div key={g.key}>
              <div className="mb-1 flex items-center justify-between">
                <p className="text-[13px] font-bold text-foreground">
                  {g.label} <span className="font-normal text-muted-foreground">· {g.nodes.length} node(s)</span>
                </p>
                <button
                  type="button"
                  className="text-[12px] text-danger hover:underline"
                  onClick={() => drop(g.nodes.map((n) => n.id))}
                >
                  remove all
                </button>
              </div>
              <ul className="divide-y divide-border rounded-md border border-border">
                {g.nodes.map((n) => (
                  <li key={n.id} className="flex items-center gap-3 px-3 py-1.5 text-[12px]">
                    <span className="w-28 shrink-0 font-semibold text-foreground">{n.type}</span>
                    <span className="min-w-0 flex-1 truncate text-muted-foreground">
                      {typeof n.name === "string" && n.name ? n.name : ""}
                      <span className="ml-2 font-mono text-[11px]">{n.id}</span>
                      {spotLinks(n, prefix).map((l) => (
                        <span key={l} className="ml-2 rounded bg-primary-tint px-1.5 py-0.5 font-mono text-[10px] text-primary-strong">
                          ⇄ {l.slice(prefix.length + 6)}
                        </span>
                      ))}
                    </span>
                    <button type="button" aria-label={`remove ${n.id}`} onClick={() => drop([n.id])}>
                      <Trash2 className="h-3.5 w-3.5 text-muted-foreground hover:text-danger" />
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
