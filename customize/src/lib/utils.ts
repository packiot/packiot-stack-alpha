import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** Weekday index → short label, used across schedule/week fields. */
export const WEEKDAYS = [
  { value: 0, label: "Sunday" },
  { value: 1, label: "Monday" },
  { value: 2, label: "Tuesday" },
  { value: 3, label: "Wednesday" },
  { value: 4, label: "Thursday" },
  { value: 5, label: "Friday" },
  { value: 6, label: "Saturday" },
] as const;

/**
 * Normalize a free-text name into an equipment/topic code: strip accents,
 * uppercase, collapse any non-alphanumeric run to a single underscore.
 * "Prensa Nº 3" → "PRENSA_N_3".
 */
export function cleanCode(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

export const TIMEZONES = [
  "America/Sao_Paulo",
  "America/Toronto",
  "America/New_York",
  "Europe/Lisbon",
  "Europe/Paris",
  "UTC",
] as const;
