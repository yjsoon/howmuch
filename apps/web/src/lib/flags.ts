export const FLAG_COLOURS = ["red", "orange", "yellow", "green", "blue", "purple"] as const;

export type FlagColour = (typeof FLAG_COLOURS)[number];

export type RewardFlagColour = FlagColour | "unflagged";

export function isFlagColour(value: string | null | undefined): value is FlagColour {
  return value != null && (FLAG_COLOURS as readonly string[]).includes(value);
}

export function flagTitle(colour: FlagColour, name?: string | null): string {
  const trimmed = name?.trim();
  return trimmed || colour[0]!.toUpperCase() + colour.slice(1);
}

/** Ledger FlagPicker uses "" for None. Rewards stores that as unflagged. */
export function rewardFlagFromLedger(value: string | null | undefined): RewardFlagColour {
  if (!value) return "unflagged";
  return isFlagColour(value) ? value : "unflagged";
}

export function ledgerFlagFromReward(value: RewardFlagColour): string {
  return value === "unflagged" ? "" : value;
}
