import { createId } from "../ids";
import { NotFoundError, ValidationError } from "../repository";
import { sanitizeSettings } from "../importers/rewards-tracker";
import type { LedgerStore } from "../storage";
import { cardFlagNames, flagNameForColour, parseCardFlagNames } from "./flag-names";
import { parseAppSettings, parseCreditCardWrite } from "./parse";
import type { AppSettings, CreditCard } from "./types";

export class RewardsAccountError extends Error {}

export async function createRewardsCard(repo: LedgerStore, planId: string, raw: unknown): Promise<CreditCard> {
  const draft = asCardObject(raw);
  const accountId = requireLiveAccountId(draft.ynabAccountId);
  if (!await repo.findLiveAccountId(planId, accountId)) {
    throw new RewardsAccountError("ynabAccountId must match a live account");
  }
  const id = optionalString(draft.id) ?? createId("card");
  const card = parseCreditCardWrite({ ...draft, id, ynabAccountId: accountId });
  await repo.upsertRewardsTrackerCard(planId, card);
  await retitleAccountFlagNames(repo, planId, card);
  return card;
}

export async function patchRewardsCard(
  repo: LedgerStore,
  planId: string,
  cardId: string,
  raw: unknown,
): Promise<CreditCard> {
  const existing = findLiveCard((await repo.getRewardsTrackerSnapshot(planId)).cards, cardId);
  if (!existing) throw new NotFoundError("Rewards card not found");
  const previousNames = parseCardFlagNames(existing.flagNames);
  const draft = { ...existing, ...asCardObject(raw), id: cardId };
  const accountId = requireLiveAccountId(draft.ynabAccountId);
  if (!await repo.findLiveAccountId(planId, accountId)) {
    throw new RewardsAccountError("ynabAccountId must match a live account");
  }
  const card = parseCreditCardWrite({ ...draft, ynabAccountId: accountId });
  await repo.upsertRewardsTrackerCard(planId, card);
  await retitleAccountFlagNames(repo, planId, card, previousNames);
  return card;
}

export async function stampTransactionFlagName(
  repo: LedgerStore,
  planId: string,
  accountId: string,
  patch: { flag_color?: string | null; flag_name?: string | null },
): Promise<void> {
  if (!Object.prototype.hasOwnProperty.call(patch, "flag_color")) return;
  if (Object.prototype.hasOwnProperty.call(patch, "flag_name")) return;
  const stored = await repo.getRewardsTrackerSnapshot(planId);
  const card = stored.cards.find((entry) => {
    return Boolean(entry && typeof entry === "object" && !Array.isArray(entry) && (entry as { ynabAccountId?: string }).ynabAccountId === accountId);
  }) as CreditCard | undefined;
  if (!card) return;
  patch.flag_name = flagNameForColour(cardFlagNames(card), patch.flag_color ?? null);
}

async function retitleAccountFlagNames(
  repo: LedgerStore,
  planId: string,
  card: CreditCard,
  previousNames?: Record<string, string>,
): Promise<void> {
  const nextNames = card.flagNames ?? {};
  const prior = previousNames ?? {};
  if (!card.flagNames && Object.keys(prior).length === 0) return;
  const colours = new Set([...Object.keys(nextNames), ...Object.keys(prior)]);
  if (colours.size === 0) return;
  const rows = await repo.listTransactions(planId, { accountId: card.ynabAccountId });
  const edits = [];
  for (const txn of rows) {
    const colour = typeof txn.flag_color === "string" && txn.flag_color ? txn.flag_color : "unflagged";
    if (!colours.has(colour)) continue;
    const next = nextNames[colour] ?? null;
    if ((txn.flag_name ?? null) === next) continue;
    edits.push({ lookup: { kind: "id" as const, id: String(txn.id) }, patch: { flag_name: next } });
  }
  if (edits.length === 0) return;
  await repo.updateTransactions(planId, edits);
}

export async function deleteRewardsCard(repo: LedgerStore, planId: string, cardId: string): Promise<object> {
  const deleted = await repo.deleteRewardsTrackerCard(planId, cardId);
  if (!deleted) throw new NotFoundError("Rewards card not found");
  return deleted;
}

export async function patchRewardsSettings(repo: LedgerStore, planId: string, raw: unknown): Promise<AppSettings> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new ValidationError("Settings must be a JSON object");
  }
  const patch = parseSettingsWrite(raw as Record<string, unknown>);
  const stored = await repo.getRewardsTrackerSnapshot(planId);
  const settings = sanitizeSettings({ ...settingsObject(stored.snapshot), ...patch });
  const saved = await repo.patchRewardsTrackerSettings(planId, settings);
  return parseAppSettings(saved);
}

export function parseSettingsWrite(body: Record<string, unknown>): { milesValuation?: number } {
  if (!Object.prototype.hasOwnProperty.call(body, "milesValuation") || body.milesValuation === undefined) {
    return {};
  }
  if (typeof body.milesValuation !== "number" || !Number.isFinite(body.milesValuation)) {
    throw new ValidationError("milesValuation must be a finite number");
  }
  return { milesValuation: body.milesValuation };
}

function asCardObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("Card must be a JSON object");
  }
  return value as Record<string, unknown>;
}

function requireLiveAccountId(value: unknown): string {
  const accountId = optionalString(value);
  if (!accountId) throw new RewardsAccountError("Card ynabAccountId is required");
  return accountId;
}

function findLiveCard(cards: unknown[], cardId: string): Record<string, unknown> | null {
  for (const entry of cards) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const card = entry as Record<string, unknown>;
    if (optionalString(card.id) === cardId) return card;
  }
  return null;
}

function settingsObject(snapshot: unknown): Record<string, unknown> {
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) return {};
  const settings = (snapshot as { settings?: unknown }).settings;
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) return {};
  return settings as Record<string, unknown>;
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}
