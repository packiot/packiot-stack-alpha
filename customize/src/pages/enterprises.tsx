import { Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "@/contexts/auth-context";
import { enterprisesApi } from "@/api/enterprises";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import type { Enterprise } from "@/types";

const PALETTE = ["#0f6bb5", "#1b3a6b", "#222", "#3ba935", "#e8541e", "#f29200", "#0b7bc1", "#e2231a", "#f07d00", "#1e8e4e"];

export function EnterprisesPage() {
  const navigate = useNavigate();
  const { signOut, user } = useAuth();
  const select = useEnterpriseStore((s) => s.select);
  const [items, setItems] = useState<Enterprise[]>([]);
  const [query, setQuery] = useState("");

  useEffect(() => {
    void enterprisesApi.list().then(setItems);
  }, []);

  const filtered = useMemo(
    () => items.filter((e) => !query.trim() || e.name.toLowerCase().includes(query.trim().toLowerCase())),
    [items, query]
  );

  function open(enterprise: Enterprise) {
    select(enterprise);
    navigate("/app/hub");
  }

  return (
    <div className="min-h-svh bg-background">
      <div className="flex h-14 items-center justify-between bg-chrome px-5">
        <div className="flex items-center gap-3.5">
          <img src="/packiot-logo.svg" alt="PackIOT" className="h-5 w-auto" />
          <span className="h-5 w-px bg-white/20" />
          <span className="flex items-center gap-1.5 text-sm font-bold text-white">
            <span className="flex h-5 w-5 items-center justify-center rounded-[5px] bg-primary text-[11px]">✦</span>
            Customization Hub
          </span>
        </div>
        <div className="flex items-center gap-3.5">
          <span className="text-[13px] text-white/60">{user?.email}</span>
          <button onClick={() => signOut().then(() => navigate("/login"))} className="rounded-md border border-white/20 px-2.5 py-1 text-xs font-semibold text-white/80 hover:bg-white/10">
            Log out
          </button>
        </div>
      </div>

      <div className="mx-auto max-w-[1160px] px-10 pb-16 pt-9">
        <div className="mb-1.5 flex items-end justify-between">
          <h1 className="text-3xl font-black tracking-tight text-foreground">Enterprises</h1>
          {/* action removed: this hub does not create enterprises (that is csadmin's job) */}
          <div className="flex w-[260px] items-center gap-2 rounded-md border border-border bg-surface px-3 py-[9px]">
            <Search className="h-[15px] w-[15px] text-muted-foreground" />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search enterprises…" className="w-full bg-transparent text-[13px] outline-none" />
          </div>
        </div>
        <p className="mb-6 text-sm text-muted-foreground">Select an enterprise to author its derive rules and review its integrations.</p>

        <div className="grid grid-cols-5 gap-4">
          {filtered.map((e, i) => (
            <div
              key={e.id_enterprise}
              onClick={() => open(e)}
              className="group relative flex aspect-[4/3] cursor-pointer flex-col items-center justify-center gap-3 rounded-[10px] border border-border bg-surface shadow-[0_1px_3px_rgba(0,0,0,0.05)] hover:border-primary hover:shadow-[0_4px_16px_rgba(0,0,0,0.12)]"
            >
              {e.logo_url ? (
                <img src={e.logo_url} alt={e.name} className="h-[52px] w-[52px] rounded-xl object-contain" />
              ) : (
                <span className="flex h-[52px] w-[52px] items-center justify-center rounded-xl text-[22px] font-black text-white" style={{ background: PALETTE[i % PALETTE.length] }}>
                  {e.name[0]}
                </span>
              )}
              <span className="text-[15px] font-extrabold text-foreground">{e.name}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
