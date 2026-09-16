import { create } from "zustand";
import { persist } from "zustand/middleware";
import type { Enterprise } from "@/types";

interface EnterpriseState {
  /** The enterprise every downstream operation is scoped to. */
  selected: Enterprise | null;
  select: (enterprise: Enterprise) => void;
  clear: () => void;
}

/**
 * Selected-enterprise store. Persisted to localStorage so a refresh keeps the
 * operator inside the enterprise they were working on. Mirrors csadmin's store
 * with a distinct persistence key so the two apps don't share selection state
 * when served on sibling subdomains.
 */
export const useEnterpriseStore = create<EnterpriseState>()(
  persist(
    (set) => ({
      selected: null,
      select: (enterprise) => set({ selected: enterprise }),
      clear: () => set({ selected: null }),
    }),
    { name: "customize.enterprise" }
  )
);
