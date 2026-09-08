import { UNFLAGGED_FLAG, YNAB_FLAG_COLORS, type YnabFlagColor } from "./flags";
import type { CreditCard } from "./types";

const FLAG_NAME_COLOURS = new Set<string>([
  UNFLAGGED_FLAG.value,
  ...YNAB_FLAG_COLORS.map((flag) => flag.value),
]);

export function parseCardFlagNames(value: unknown): Record<string, string> | undefined {
  if (value == null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) return undefined;
  const names: Record<string, string> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (!FLAG_NAME_COLOURS.has(key) || typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (trimmed) names[key] = trimmed;
  }
  return Object.keys(names).length > 0 ? names : undefined;
}

export function cardFlagNames(card: Pick<CreditCard, "flagNames" | "subcategories">): Record<string, string> {
  const names: Record<string, string> = {};
  for (const flag of card.subcategories ?? []) {
    const trimmed = flag.name.trim();
    if (trimmed) names[flag.flagColor] = trimmed;
  }
  for (const [colour, name] of Object.entries(card.flagNames ?? {})) {
    const trimmed = name.trim();
    if (trimmed) names[colour] = trimmed;
  }
  return names;
}

export function flagNameForColour(names: Record<string, string>, flagColor: string | null | undefined): string | null {
  if (!flagColor) {
    return names[UNFLAGGED_FLAG.value]?.trim() || null;
  }
  return names[flagColor.toLowerCase()]?.trim() || null;
}
