import { useSyncExternalStore } from "react";

/** The phone breakpoint, matching the ≤720px blocks in app.css. */
const PHONE_QUERY = "(max-width: 720px)";

function subscribe(onChange: () => void): () => void {
  const query = window.matchMedia?.(PHONE_QUERY);
  query?.addEventListener("change", onChange);
  return () => query?.removeEventListener("change", onChange);
}

const isPhone = () => window.matchMedia?.(PHONE_QUERY).matches ?? false;

/** True while the viewport is phone-width; follows rotation and resizing. */
export function useIsPhone(): boolean {
  return useSyncExternalStore(subscribe, isPhone, () => false);
}
