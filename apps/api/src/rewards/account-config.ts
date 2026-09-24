import { createHash } from "node:crypto";
import { NotFoundError, ValidationError } from "../repository";
import type { LedgerStore } from "../storage";
import { UNFLAGGED_FLAG, YNAB_FLAG_COLORS } from "./flags";
import { parseCreditCardWrite } from "./parse";
import type { CreditCard } from "./types";

export type RewardsAccountConfig = {
  format: "rewards-account-config";
  version: 1;
  card: Omit<CreditCard, "id" | "ynabAccountId" | "featured">;
};

export function parseRewardsAccountConfig(value: unknown): RewardsAccountConfig {
  const file = object(value);
  if (file.format !== "rewards-account-config" || file.version !== 1) {
    throw new ValidationError("Choose a rewards-account-config version 1 file, not a whole-app settings export");
  }
  const raw = object(file.card);
  if (raw.type !== "cashback" && raw.type !== "miles") {
    throw new ValidationError("Card type must be cashback or miles");
  }
  if (typeof raw.issuer !== "string") throw new ValidationError("Card issuer must be a string");
  if (raw.subcategoriesEnabled !== undefined && typeof raw.subcategoriesEnabled !== "boolean") {
    throw new ValidationError("subcategoriesEnabled must be a boolean");
  }
  if (Array.isArray(raw.subcategories)) {
    for (const entry of raw.subcategories) {
      const category = object(entry);
      for (const key of ["active", "excludeFromRewards"]) {
        if (category[key] !== undefined && typeof category[key] !== "boolean") throw new ValidationError(`${key} must be a boolean`);
      }
    }
  }
  if (raw.flagNames !== undefined) {
    const names = object(raw.flagNames);
    const colours = [UNFLAGGED_FLAG.value, ...YNAB_FLAG_COLORS.map((flag) => flag.value)] as string[];
    for (const [colour, name] of Object.entries(names)) {
      if (!colours.includes(colour) || typeof name !== "string") throw new ValidationError("flagNames must map supported flag colours to strings");
    }
  }
  // The existing parser projects known fields at every level. Identity and
  // presentation belong to the destination, never to the imported document.
  const { id, ynabAccountId, featured, ...card } = parseCreditCardWrite({
    ...raw, id: "config", ynabAccountId: "config", featured: true,
  });
  const ids = (card.subcategories ?? []).map((category) => category.id);
  if (new Set(ids).size !== ids.length) throw new ValidationError("Subcategory ids must be unique");
  const colours = (card.subcategories ?? []).map((category) => category.flagColor);
  if (new Set(colours).size !== colours.length) throw new ValidationError("Subcategory flag colours must be unique for Rewards Tracker exchange");
  const tiers = card.spendingTiers ?? [];
  if (new Set(tiers.map((tier) => tier.id)).size !== tiers.length) throw new ValidationError("Tier ids must be unique");
  for (const tier of tiers) {
    const references = (tier.subcategories ?? []).map((override) => override.subcategoryId);
    if (new Set(references).size !== references.length) throw new ValidationError("Tier subcategory overrides must be unique");
    for (const override of tier.subcategories ?? []) {
      if (!ids.includes(override.subcategoryId)) throw new ValidationError("Tier override must reference an exported subcategory");
    }
  }
  return { format: "rewards-account-config", version: 1, card };
}

export async function exportRewardsAccountConfig(repo: LedgerStore, planId: string, accountId: string): Promise<RewardsAccountConfig> {
  if (!await repo.findLiveAccountId(planId, accountId)) throw new NotFoundError("Account not found");
  const card = await accountCard(repo, planId, accountId);
  if (!card) throw new NotFoundError("This account has no rewards configuration to export");
  return parseRewardsAccountConfig({ format: "rewards-account-config", version: 1, card });
}

export async function importRewardsAccountConfig(repo: LedgerStore, planId: string, accountId: string, value: unknown): Promise<CreditCard> {
  const file = parseRewardsAccountConfig(value);
  if (!await repo.findLiveAccountId(planId, accountId)) throw new NotFoundError("Account not found");
  const account = await repo.getAccount(planId, accountId);
  const existing = await accountCard(repo, planId, accountId);
  const card = parseCreditCardWrite({
    ...file.card,
    // Concurrent first imports must target the same row, even across Workers.
    id: existing?.id ?? `card_config_${createHash("sha256").update(JSON.stringify([planId, accountId])).digest("hex")}`,
    ynabAccountId: accountId,
    name: existing?.name ?? account.name,
    featured: existing?.featured ?? true,
  });
  // Unlike an editor save, importing configuration must not retitle ledger rows.
  // Replacing this card (rather than patch-merging) clears omitted old limits.
  await repo.upsertRewardsTrackerCard(planId, card);
  return card;
}

async function accountCard(repo: LedgerStore, planId: string, accountId: string): Promise<CreditCard | undefined> {
  const cards = (await repo.getRewardsTrackerSnapshot(planId)).cards.filter((entry) =>
    entry && typeof entry === "object" && "ynabAccountId" in entry && entry.ynabAccountId === accountId,
  ) as CreditCard[];
  if (cards.length > 1) throw new ValidationError("This account has multiple rewards cards; resolve them before exchanging configuration");
  return cards[0];
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ValidationError("Rewards configuration must be a JSON object");
  return value as Record<string, unknown>;
}
