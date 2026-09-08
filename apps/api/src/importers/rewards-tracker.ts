import { ValidationError } from "../repository";
import type { LedgerStore } from "../storage";
import type { TransactionInput } from "../types";

const SOURCE_KIND = "rewards-tracker-export";

export type RewardsTrackerCard = {
  id: string;
  name: string;
  issuer: string;
  type: string;
  ynabAccountId: string;
  [key: string]: unknown;
};

export type RewardsTrackerPortablePayload = {
  ynab: {
    selectedBudgetId?: string;
    selectedBudgetName?: string;
    trackedAccountIds: string[];
  };
  cards: RewardsTrackerCard[];
  rules: unknown[];
  tagMappings: unknown[];
  calculations: [];
  themeGroups: unknown[];
  hiddenCards: unknown[];
  settings: Record<string, unknown>;
};

export type RewardsTrackerAccount = {
  id: string;
  name: string;
  type?: string;
  on_budget?: boolean;
  closed?: boolean;
  balance?: number;
  fromCache: boolean;
};

export type ParsedRewardsTrackerExport = {
  portable: RewardsTrackerPortablePayload;
  flagNames: Record<string, string>;
  accounts: RewardsTrackerAccount[];
  transactions: Array<Record<string, unknown>>;
};

export type RewardsTrackerImportResult = {
  import_session_id: string;
  cards: number;
  rules: number;
  tag_mappings: number;
  theme_groups: number;
  accounts_upserted: number;
  transactions_imported: number;
  transactions_updated: number;
  flag_names: number;
};

export function parseRewardsTrackerExport(input: unknown): ParsedRewardsTrackerExport {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new ValidationError("Rewards Tracker export must be a JSON object");
  }

  const raw = input as Record<string, unknown>;
  if (!Array.isArray(raw.cards)) {
    throw new ValidationError("Rewards Tracker export must include a cards array");
  }

  const cards = raw.cards.map((card, index) => parseCard(card, index));
  const ynab = parseYnab(raw.ynab);
  const settings = sanitizeSettings(raw.settings);
  const cached = raw.cachedData && typeof raw.cachedData === "object" && !Array.isArray(raw.cachedData)
    ? raw.cachedData as Record<string, unknown>
    : {};

  const portable: RewardsTrackerPortablePayload = {
    ynab,
    cards,
    rules: asArray(raw.rules),
    tagMappings: asArray(raw.tagMappings),
    calculations: [],
    themeGroups: asArray(raw.themeGroups),
    hiddenCards: asArray(raw.hiddenCards),
    settings,
  };

  return {
    portable,
    flagNames: parseFlagNames(cached.flagNames),
    accounts: collectAccounts(portable, cached),
    transactions: collectTransactions(cached),
  };
}

export async function importRewardsTrackerExport(
  repo: LedgerStore,
  planId: string,
  input: unknown,
): Promise<RewardsTrackerImportResult> {
  const parsed = parseRewardsTrackerExport(input);
  const sessionId = await repo.createImportSession(planId, SOURCE_KIND);

  try {
    const existing = await repo.getRewardsTrackerSnapshot(planId);
    parsed.portable.settings = mergeImportedMilesValuation(existing.snapshot, parsed.portable.settings);
    await repo.upsertRewardsTrackerSnapshot(planId, parsed.portable);

    const existingSettings = await repo.getSettings(planId);
    const existingPlan = await repo.getPlan(planId);
    const flagNames = { ...(existingSettings.display?.flag_names ?? {}), ...parsed.flagNames };
    await repo.upsertPlan(
      planId,
      {
        id: planId,
        name: parsed.portable.ynab.selectedBudgetName ?? existingPlan.name,
      },
      {
        date_format: existingSettings.date_format,
        currency_format: mergeCurrency(existingSettings.currency_format, parsed.portable.settings.currency),
        display: { flag_names: flagNames },
      },
    );

    const accountIds = new Set<string>();
    for (const account of parsed.accounts) {
      if (account.fromCache && typeof account.balance === "number") {
        await repo.upsertAccount(planId, {
          id: account.id,
          name: account.name,
          type: account.type ?? "creditCard",
          on_budget: account.on_budget,
          closed: account.closed,
          balance: account.balance,
          external_ynab_id: account.id,
        });
      } else {
        await repo.ensureAccount(planId, account.id, account.name);
      }
      accountIds.add(account.id);
    }

    let imported = 0;
    let updated = 0;
    for (const [index, transaction] of parsed.transactions.entries()) {
      const written = await upsertCachedTransaction(repo, planId, sessionId, index, transaction);
      if (written === "imported") imported += 1;
      if (written === "updated") updated += 1;
    }

    const summary = {
      cards: parsed.portable.cards.length,
      rules: parsed.portable.rules.length,
      tag_mappings: parsed.portable.tagMappings.length,
      theme_groups: parsed.portable.themeGroups.length,
      accounts_upserted: accountIds.size,
      transactions_imported: imported,
      transactions_updated: updated,
      flag_names: Object.keys(parsed.flagNames).length,
    };
    await repo.finishImportSession(sessionId, "completed", summary);
    return { import_session_id: sessionId, ...summary };
  } catch (error) {
    await repo.finishImportSession(sessionId, "failed", { error: error instanceof Error ? error.message : String(error) });
    throw error;
  }
}

async function upsertCachedTransaction(
  repo: LedgerStore,
  planId: string,
  sessionId: string,
  index: number,
  raw: Record<string, unknown>,
): Promise<"imported" | "updated" | "skipped"> {
  const id = optionalString(raw.id);
  const accountId = optionalString(raw.account_id);
  const date = optionalString(raw.date);
  const amount = typeof raw.amount === "number" && Number.isFinite(raw.amount) ? raw.amount : null;
  if (!id || !accountId || !date || amount == null) {
    await repo.recordImportRow(sessionId, index, "failed", raw, "Cached transaction is missing id, account_id, date, or amount");
    return "skipped";
  }

  const existing = await repo.findYnabImportTarget(planId, {
    id,
    account_id: accountId,
    date,
    amount,
    import_id: optionalString(raw.import_id),
  });
  const input: TransactionInput = {
    id: existing?.id ?? id,
    account_id: accountId,
    date,
    amount,
    payee_name: optionalString(raw.payee_name) ?? existing?.payee_name ?? null,
    category_id: optionalString(raw.category_id) ?? existing?.category_id ?? null,
    memo: optionalString(raw.memo) ?? existing?.memo ?? null,
    cleared: parseCleared(raw.cleared) ?? existing?.cleared ?? "uncleared",
    approved: typeof raw.approved === "boolean" ? raw.approved : existing?.approved ?? true,
    flag_color: optionalString(raw.flag_color) ?? existing?.flag_color ?? null,
    flag_name: optionalString(raw.flag_name) ?? existing?.flag_name ?? null,
    transfer_account_id: optionalString(raw.transfer_account_id) ?? existing?.transfer_account_id ?? null,
    transfer_transaction_id: optionalString(raw.transfer_transaction_id) ?? existing?.transfer_transaction_id ?? null,
    import_id: optionalString(raw.import_id) ?? existing?.import_id ?? null,
    source_kind: SOURCE_KIND,
    source_ref: sessionId,
    external_ynab_id: existing?.external_ynab_id ?? id,
  };

  const transaction = await repo.createTransaction(planId, input, { autoLink: false });
  await repo.recordImportRow(sessionId, index, existing ? "duplicate" : "imported", raw, undefined, transaction.id);
  return existing ? "updated" : "imported";
}

function parseCard(value: unknown, index: number): RewardsTrackerCard {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError(`cards[${index}] must be an object`);
  }
  const card = value as Record<string, unknown>;
  const id = optionalString(card.id);
  const name = optionalString(card.name);
  const accountId = optionalString(card.ynabAccountId);
  if (!id || !name || !accountId) {
    throw new ValidationError(`cards[${index}] needs id, name, and ynabAccountId`);
  }
  return {
    ...card,
    id,
    name,
    issuer: optionalString(card.issuer) ?? "",
    type: optionalString(card.type) ?? "cashback",
    ynabAccountId: accountId,
  };
}

function parseYnab(value: unknown): RewardsTrackerPortablePayload["ynab"] {
  if (value == null) {
    return { trackedAccountIds: [] };
  }
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("ynab must be an object");
  }
  const ynab = value as Record<string, unknown>;
  return {
    selectedBudgetId: optionalString(ynab.selectedBudgetId),
    selectedBudgetName: optionalString(ynab.selectedBudgetName),
    trackedAccountIds: stringList(ynab.trackedAccountIds),
  };
}

export function sanitizeSettings(value: unknown): Record<string, unknown> {
  if (value == null) return {};
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("settings must be an object");
  }
  const settings = { ...(value as Record<string, unknown>) };
  delete settings.cloudSyncKeyId;
  delete settings.cloudSyncLastSyncedAt;
  delete settings.cloudSyncLocalChangedAt;
  delete settings.cloudSyncMnemonic;
  delete settings.rememberCloudSyncCode;
  delete settings.autoSyncEnabled;
  if (settings.statementFormatter && typeof settings.statementFormatter === "object" && !Array.isArray(settings.statementFormatter)) {
    const formatter = { ...(settings.statementFormatter as Record<string, unknown>) };
    delete formatter.apiKeys;
    settings.statementFormatter = formatter;
  }
  return settings;
}

function parseFlagNames(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const names: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value)) {
    const name = optionalString(entry);
    if (name) names[key] = name;
  }
  return names;
}

function collectAccounts(
  portable: RewardsTrackerPortablePayload,
  cached: Record<string, unknown>,
): RewardsTrackerAccount[] {
  const byId = new Map<string, RewardsTrackerAccount>();

  for (const entry of asArray(cached.accounts)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const accounts = asArray((entry as Record<string, unknown>).accounts);
    for (const account of accounts) rememberAccount(byId, account);
  }

  for (const entry of asArray(cached.dashboardTransactions)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    for (const account of asArray((entry as Record<string, unknown>).accounts)) rememberAccount(byId, account);
  }

  for (const card of portable.cards) {
    if (!byId.has(card.ynabAccountId)) {
      byId.set(card.ynabAccountId, { id: card.ynabAccountId, name: card.name, type: "creditCard", fromCache: false });
    }
  }

  for (const accountId of portable.ynab.trackedAccountIds) {
    if (!byId.has(accountId)) {
      byId.set(accountId, { id: accountId, name: accountId, type: "creditCard", fromCache: false });
    }
  }

  return [...byId.values()];
}

function rememberAccount(byId: Map<string, RewardsTrackerAccount>, value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  const account = value as Record<string, unknown>;
  const id = optionalString(account.id);
  const name = optionalString(account.name);
  if (!id || !name) return;
  const next: RewardsTrackerAccount = {
    id,
    name,
    type: optionalString(account.type),
    on_budget: typeof account.on_budget === "boolean" ? account.on_budget : undefined,
    closed: typeof account.closed === "boolean" ? account.closed : undefined,
    balance: typeof account.balance === "number" ? account.balance : undefined,
    fromCache: typeof account.balance === "number",
  };
  const existing = byId.get(id);
  if (!existing) {
    byId.set(id, next);
    return;
  }
  byId.set(id, {
    ...existing,
    ...Object.fromEntries(Object.entries(next).filter(([, value]) => value !== undefined)),
    fromCache: existing.fromCache || next.fromCache,
  });
}

function collectTransactions(cached: Record<string, unknown>): Array<Record<string, unknown>> {
  const byId = new Map<string, Record<string, unknown>>();
  for (const entry of asArray(cached.dashboardTransactions)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    for (const transaction of asArray((entry as Record<string, unknown>).transactions)) {
      if (!transaction || typeof transaction !== "object" || Array.isArray(transaction)) continue;
      const id = optionalString((transaction as Record<string, unknown>).id);
      if (id) byId.set(id, transaction as Record<string, unknown>);
    }
  }
  for (const transaction of asArray(cached.transactions)) {
    if (!transaction || typeof transaction !== "object" || Array.isArray(transaction)) continue;
    const id = optionalString((transaction as Record<string, unknown>).id);
    if (id && !byId.has(id)) byId.set(id, transaction as Record<string, unknown>);
  }
  return [...byId.values()];
}

function mergeImportedMilesValuation(
  snapshot: unknown,
  settings: Record<string, unknown>,
): Record<string, unknown> {
  if (finiteNumber(settings.milesValuation) !== undefined) return settings;
  const existing = snapshot && typeof snapshot === "object" && !Array.isArray(snapshot)
    ? (snapshot as { settings?: unknown }).settings
    : undefined;
  const kept = existing && typeof existing === "object" && !Array.isArray(existing)
    ? finiteNumber((existing as { milesValuation?: unknown }).milesValuation)
    : undefined;
  if (kept === undefined) return settings;
  return { ...settings, milesValuation: kept };
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function mergeCurrency(existing: Record<string, unknown> | undefined, currency: unknown): Record<string, unknown> | undefined {
  const iso = optionalString(currency);
  if (!iso) return existing;
  return { ...(existing ?? {}), iso_code: iso };
}

function parseCleared(value: unknown): TransactionInput["cleared"] | undefined {
  const normalised = optionalString(value)?.toLowerCase();
  if (normalised === "cleared" || normalised === "reconciled" || normalised === "uncleared") {
    return normalised;
  }
  return undefined;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.map((entry) => optionalString(entry)).filter((entry): entry is string => Boolean(entry)))];
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}
