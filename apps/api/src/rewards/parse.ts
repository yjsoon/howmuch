import type { AppSettings, CreditCard, RewardGroupBy } from "./types";

export function parseRewardGroupBy(value: string | null | undefined): RewardGroupBy {
  if (value === "payee" || value === "category" || value === "memo" || value === "flag") return value;
  return "flag";
}

export function parseAppSettings(value: unknown): AppSettings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const raw = value as Record<string, unknown>;
  const miles = typeof raw.milesValuation === "number" && Number.isFinite(raw.milesValuation)
    ? raw.milesValuation
    : undefined;
  return {
    currency: typeof raw.currency === "string" ? raw.currency : undefined,
    milesValuation: miles,
    dashboardViewMode: raw.dashboardViewMode === "detailed" ? "detailed" : "summary",
    groupCardsByType: raw.groupCardsByType === false ? false : true,
  };
}

export function parseCreditCards(value: unknown): CreditCard[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    const card = parseCreditCard(entry);
    return card ? [card] : [];
  });
}

function parseCreditCard(value: unknown): CreditCard | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const id = stringValue(raw.id);
  const name = stringValue(raw.name);
  const accountId = stringValue(raw.ynabAccountId);
  if (!id || !name || !accountId) return null;
  const type = raw.type === "miles" ? "miles" : "cashback";
  return {
    ...(raw as CreditCard),
    id,
    name,
    issuer: stringValue(raw.issuer) ?? "",
    type,
    ynabAccountId: accountId,
    featured: raw.featured !== false,
  };
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
