import { FLAG_COLOURS, isFlagColour, type RewardFlagColour } from "./flags";

export const REWARD_NAME_COLOURS: readonly RewardFlagColour[] = [...FLAG_COLOURS, "unflagged"];

export function parseRewardFlagNames(value: unknown): Partial<Record<RewardFlagColour, string>> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const names: Partial<Record<RewardFlagColour, string>> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    const colour: RewardFlagColour | null = key === "unflagged" ? "unflagged" : isFlagColour(key) ? key : null;
    if (!colour || typeof raw !== "string") continue;
    const trimmed = raw.trim();
    if (trimmed) names[colour] = trimmed;
  }
  return names;
}

export function namesFromSubcategories(
  flags: Array<{ flagColor: RewardFlagColour; name: string }>,
): Partial<Record<RewardFlagColour, string>> {
  const names: Partial<Record<RewardFlagColour, string>> = {};
  for (const flag of flags) {
    const trimmed = flag.name.trim();
    if (trimmed && !names[flag.flagColor]) names[flag.flagColor] = trimmed;
  }
  return names;
}

export function ledgerFlagNames(names: Partial<Record<RewardFlagColour, string>>): Record<string, string> {
  const mapped: Record<string, string> = {};
  for (const colour of FLAG_COLOURS) {
    const name = names[colour]?.trim();
    if (name) mapped[colour] = name;
  }
  const unflagged = names.unflagged?.trim();
  if (unflagged) mapped[""] = unflagged;
  return mapped;
}

export function namedFlagLabel(
  names: Partial<Record<RewardFlagColour, string>> | undefined,
  colour: string | null | undefined,
  fallback?: string | null,
): string | undefined {
  const key: RewardFlagColour | null = !colour ? "unflagged" : isFlagColour(colour) ? colour : null;
  const named = key ? names?.[key]?.trim() : undefined;
  return named || fallback?.trim() || undefined;
}

export function sameFlagColour(left: string | null | undefined, right: string | null | undefined): boolean {
  return (left || null) === (right || null);
}

export function snapshotFlagLabel(
  names: Partial<Record<RewardFlagColour, string>> | undefined,
  colour: string | null | undefined,
  snapshot: { flag_color?: string | null; flag_name?: string | null },
): string | undefined {
  return namedFlagLabel(
    names,
    colour,
    sameFlagColour(colour, snapshot.flag_color) ? snapshot.flag_name : undefined,
  );
}

export function colourNamesForCard(card: {
  flagNames?: Record<string, string>;
  subcategories?: Array<{ flagColor: RewardFlagColour; name: string }>;
}): Partial<Record<RewardFlagColour, string>> {
  return {
    ...namesFromSubcategories(card.subcategories ?? []),
    ...parseRewardFlagNames(card.flagNames),
  };
}

export function colourNamesByAccount(
  cards: Array<{
    ynabAccountId: string;
    flagNames?: Record<string, string>;
    subcategories?: Array<{ flagColor: RewardFlagColour; name: string }>;
  }> | undefined,
): Map<string, Partial<Record<RewardFlagColour, string>>> {
  const mapped = new Map<string, Partial<Record<RewardFlagColour, string>>>();
  for (const card of cards ?? []) {
    mapped.set(card.ynabAccountId, colourNamesForCard(card));
  }
  return mapped;
}
