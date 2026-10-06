import { useSyncExternalStore } from "react";
import { withViewTransition } from "./view-transition";

/** Keep in step with public/theme-boot.js, which applies the same prefs before first paint. */
export const LOOKS = [
  { id: "dusk-ridge", name: "Dusk Ridge", note: "Plum dusk chrome, amber bloom. The mark, unfolded.", meta: ["#2b1f2c", "#120d13"] },
  { id: "ridge-charcoal", name: "Ridge Charcoal", note: "Quiet charcoal chrome with a safelight edge.", meta: ["#242722", "#0b0c0c"] },
  { id: "overexposed", name: "Overexposed", note: "Everything lit: paper on paper, sun in the corner.", meta: ["#fbf7ef", "#1a1613"] },
] as const;
export type Look = (typeof LOOKS)[number]["id"];
export type Mode = "system" | "light" | "dark";
export type ThemePrefs = { look: Look; mode: Mode };

const KEY = "howmuch.theme.v1";
const DEFAULT: ThemePrefs = { look: "dusk-ridge", mode: "system" };
const listeners = new Set<() => void>();
let current = read();

function read(): ThemePrefs {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? "null");
    return {
      look: LOOKS.some((l) => l.id === raw?.look) ? raw.look : DEFAULT.look,
      mode: raw?.mode === "light" || raw?.mode === "dark" ? raw.mode : "system",
    };
  } catch {
    return DEFAULT;
  }
}

const systemDark = () => window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;

/** Writes the resolved `data-theme` / `data-mode` attributes and the browser chrome colour. Idempotent. */
export function applyTheme(prefs: ThemePrefs): void {
  const dark = prefs.mode === "dark" || (prefs.mode === "system" && systemDark());
  const root = document.documentElement;
  root.dataset.theme = prefs.look;
  root.dataset.mode = dark ? "dark" : "light";
  const look = LOOKS.find((l) => l.id === prefs.look) ?? LOOKS[0];
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", look.meta[dark ? 1 : 0]);
}

/** Saves the choice on this device (not cleared on sign-out: it is not ledger data) and cross-fades to it. */
export function setTheme(next: ThemePrefs): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    /* storage blocked: the choice lasts for this session only */
  }
  withViewTransition("theme", () => {
    current = next;
    applyTheme(next);
    listeners.forEach((listener) => listener());
  });
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const mq = window.matchMedia?.("(prefers-color-scheme: dark)");
  const onSystem = () => {
    if (current.mode === "system") applyTheme(current);
  };
  const onStorage = (event: StorageEvent) => {
    if (event.key === KEY) {
      current = read();
      applyTheme(current);
      listener();
    }
  };
  mq?.addEventListener("change", onSystem);
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    mq?.removeEventListener("change", onSystem);
    window.removeEventListener("storage", onStorage);
  };
}

export function useTheme(): ThemePrefs {
  return useSyncExternalStore(subscribe, () => current);
}

/** The prefs read at module load, for the one-off `applyTheme` call in main.tsx. */
export function currentTheme(): ThemePrefs {
  return current;
}
