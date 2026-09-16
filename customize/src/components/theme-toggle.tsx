import { Moon, Sun } from "lucide-react";
import { useThemeStore } from "@/stores/theme-store";

/**
 * Day/night toggle for the top bar. Styled to match the header's circular
 * icon buttons (the Log-out button next to it). Shows a Sun while dark (click
 * -> go light) and a Moon while light (click -> go dark). csadmin's toggle
 * without the i18n wrapper (this standalone app has no i18n runtime).
 */
export function ThemeToggle() {
  const theme = useThemeStore((s) => s.theme);
  const toggle = useThemeStore((s) => s.toggle);
  const isDark = theme === "dark";
  const label = isDark ? "Switch to light mode" : "Switch to dark mode";

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      className="flex h-8 w-8 items-center justify-center rounded-full bg-white/10 text-white transition-colors hover:bg-white/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/70 motion-reduce:transition-none"
    >
      {isDark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
    </button>
  );
}
