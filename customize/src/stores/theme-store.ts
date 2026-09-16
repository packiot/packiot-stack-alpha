import { create } from "zustand";

export type Theme = "light" | "dark";

/** localStorage key — kept in sync with the FOUC guard script in index.html. */
export const THEME_STORAGE_KEY = "customize.theme";

/**
 * Resolve the boot theme: an explicit persisted choice wins; otherwise fall
 * back to the OS preference. Mirrors the inline guard in index.html, so the
 * store's initial value always matches the class already on <html> (no flash,
 * no re-paint on mount).
 */
function getInitialTheme(): Theme {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored === "light" || stored === "dark") return stored;
  } catch {
    // localStorage can throw in private-mode / sandboxed contexts — ignore.
  }
  return window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

/** Apply the theme by toggling the `.dark` class that every token keys off. */
function applyTheme(theme: Theme) {
  document.documentElement.classList.toggle("dark", theme === "dark");
}

interface ThemeState {
  theme: Theme;
  /** Flip light <-> dark, persist, and apply to <html>. */
  toggle: () => void;
  /** Set an explicit theme, persist, and apply to <html>. */
  setTheme: (theme: Theme) => void;
}

/**
 * Theme store. Applies + persists on every change so the choice survives a
 * refresh (read back by both this store and the FOUC guard in index.html).
 */
export const useThemeStore = create<ThemeState>((set, get) => ({
  theme: getInitialTheme(),
  toggle: () => get().setTheme(get().theme === "dark" ? "light" : "dark"),
  setTheme: (theme) => {
    try {
      localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch {
      // Best-effort persistence; still apply for this session.
    }
    applyTheme(theme);
    set({ theme });
  },
}));
