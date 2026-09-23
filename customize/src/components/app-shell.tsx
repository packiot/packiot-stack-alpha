import { Braces, Database, Gauge, LayoutGrid, LogOut, Repeat } from "lucide-react";
import { NavLink, Navigate, Outlet, useNavigate } from "react-router-dom";
import { useAuth } from "@/contexts/auth-context";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import { ThemeToggle } from "@/components/theme-toggle";
import { cn } from "@/lib/utils";

// Minimal fixed nav — the Customization Hub is a focused three-surface app
// (unlike csadmin's full topology tree). No i18n runtime here: labels are the
// hardcoded English source.
type NavLeaf = { to: string; label: string; icon: typeof LayoutGrid };

const NAV: NavLeaf[] = [
  { to: "/app/hub", label: "Hub", icon: LayoutGrid },
  { to: "/app/customizations", label: "Derive rules", icon: Braces },
  { to: "/app/oee-profile", label: "OEE Computation", icon: Gauge },
  { to: "/app/integrations", label: "Integrations", icon: Database },
];

const leafClass = ({ isActive }: { isActive: boolean }) =>
  cn(
    "flex items-center gap-[11px] rounded-md px-3 py-2 text-sm font-semibold transition-colors",
    isActive ? "bg-primary text-white" : "text-white/70 hover:bg-white/10"
  );

function Leaf({ to, label, icon: Icon }: NavLeaf) {
  return (
    <NavLink to={to} className={leafClass} end>
      <Icon className="h-[18px] w-[18px]" />
      {label}
    </NavLink>
  );
}

export function AppShell() {
  const navigate = useNavigate();
  const { signOut } = useAuth();
  const enterprise = useEnterpriseStore((s) => s.selected);
  const clear = useEnterpriseStore((s) => s.clear);

  if (!enterprise) return <Navigate to="/enterprises" replace />;

  async function handleSignOut() {
    await signOut();
    navigate("/login", { replace: true });
  }

  return (
    <div className="flex h-svh flex-col overflow-hidden bg-background">
      {/* top bar */}
      <header className="flex h-14 flex-none items-center justify-between bg-chrome px-5 text-white">
        <div className="flex items-center gap-3.5">
          <img src="/packiot-logo.svg" alt="PackIOT" className="h-5 w-auto" />
          <span className="h-5 w-px bg-white/20" />
          <span className="flex items-center gap-1.5 text-[13px] font-bold text-white/90">
            <span className="flex h-[18px] w-[18px] items-center justify-center rounded-[5px] bg-primary text-[10px]">
              ✦
            </span>
            Customization Hub
          </span>
        </div>
        <div className="flex items-center gap-2.5">
          <span className="flex h-[26px] w-[26px] items-center justify-center rounded-md bg-white text-[12px] font-black text-chrome">
            {enterprise.code?.[0] ?? enterprise.name[0]}
          </span>
          <span className="text-[15px] font-bold">{enterprise.name}</span>
          <button
            onClick={() => {
              clear();
              navigate("/enterprises");
            }}
            className="flex items-center gap-1.5 rounded-md border border-white/20 px-2.5 py-1 text-xs font-semibold text-white/80 hover:bg-white/10"
          >
            <Repeat className="h-3 w-3" />
            Switch
          </button>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <button
            onClick={handleSignOut}
            title="Log out"
            className="flex h-8 w-8 items-center justify-center rounded-full bg-white/10 text-white hover:bg-white/20"
          >
            <LogOut className="h-4 w-4" />
          </button>
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        <nav className="flex w-56 flex-none flex-col gap-[3px] overflow-y-auto bg-chrome p-3">
          {NAV.map((leaf) => (
            <Leaf key={leaf.to} {...leaf} />
          ))}
        </nav>
        <main className="flex-1 overflow-auto p-8">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
