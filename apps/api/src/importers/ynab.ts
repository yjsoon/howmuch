import type { LedgerStore } from "../storage";

export type YnabImportOptions = {
  token: string;
  planId: string;
  baseUrl?: string;
  sinceDate?: string;
  /**
   * When set, the fetched YNAB transactions must be at least this similar
   * (0..1, matched by id/date/amount) to the transactions already imported
   * from YNAB, or the import is skipped without writing anything. Protects a
   * populated ledger from being resynced against the wrong budget or a
   * token that suddenly returns very different data. Ledgers with no prior
   * YNAB import are never blocked by this check.
   */
  minSimilarity?: number;
  /** YNAB delta cursor. Omit for the initial full-history import. */
  lastKnowledgeOfServer?: number;
  /** Receives non-fatal warnings, e.g. the token nearing its rate limit. */
  warn?: (message: string) => void;
  /** Internal hosted-storage hook used to renew a scheduler lease during long imports. */
  progress?: () => Promise<void>;
};

export type YnabImportResult = {
  import_session_id: string;
  imported_transactions: number;
  raw_objects?: Record<string, number>;
  skipped?: boolean;
  similarity?: number;
  server_knowledge?: number;
};

export type YnabPlanSummary = {
  id: string;
  name: string;
  last_modified_on?: string;
};

const DEFAULT_YNAB_BASE_URL = "https://api.ynab.com/v1";

export async function importYnabFromApi(
  repo: LedgerStore,
  options: YnabImportOptions,
): Promise<YnabImportResult> {
  const baseUrl = options.baseUrl ?? DEFAULT_YNAB_BASE_URL;
  const sinceDate = options.sinceDate ?? "1900-01-01";
  const sessionId = await repo.createImportSession(options.planId, "ynab-api");
  const warn = dedupedWarn(options.warn);

  try {
    const delta = options.lastKnowledgeOfServer == null
      ? ""
      : `?last_knowledge_of_server=${encodeURIComponent(String(options.lastKnowledgeOfServer))}`;
    const transactionQuery = options.lastKnowledgeOfServer == null
      ? `?since_date=${encodeURIComponent(sinceDate)}`
      : delta;
    // A plan detail response is YNAB's full export and, when asked with a
    // cursor, its delta export.  Older test doubles and private API proxies
    // may only implement the legacy collection endpoints, so retain a narrow
    // fallback without making the production import lossy.
    const full = await ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}${delta}`, warn);
    const fullPlan = full?.data?.plan ?? full?.data?.budget;
    let plan: any;
    let settings: any;
    let accounts: any;
    let categories: any;
    let payees: any;
    let transactions: any;
    let moneyMovements: any = null;
    let moneyMovementGroups: any = null;
    if (hasFullPlanCollections(fullPlan)) {
      [settings, moneyMovements, moneyMovementGroups] = await Promise.all([
        ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}/settings`, warn),
        // These endpoints have no cursor, so refresh their small full lists
        // on every pass.  Keeping an old movement list would silently lose
        // data created after the first migration.
        ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}/money_movements`, warn),
        ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}/money_movement_groups`, warn),
      ]);
      plan = { data: { plan: fullPlan, server_knowledge: full?.data?.server_knowledge } };
      accounts = { data: { accounts: fullPlan.accounts ?? [], server_knowledge: full?.data?.server_knowledge } };
      categories = { data: { category_groups: fullPlan.category_groups ?? [], ...(Array.isArray(fullPlan.categories) ? { categories: fullPlan.categories } : {}), server_knowledge: full?.data?.server_knowledge } };
      payees = { data: { payees: fullPlan.payees ?? [], server_knowledge: full?.data?.server_knowledge } };
      transactions = { data: { transactions: fullPlan.transactions ?? [], subtransactions: fullPlan.subtransactions ?? [], server_knowledge: full?.data?.server_knowledge } };
    } else {
      const legacy = await Promise.all([
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}`, warn),
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}/settings`, warn),
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}/accounts${delta}`, warn),
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}/categories${delta}`, warn),
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}/payees${delta}`, warn),
        ynabFetch(baseUrl, options.token, `/plans/${options.planId}/transactions${transactionQuery}`, warn),
      ]);
      [plan, settings, accounts, categories, payees, transactions] = legacy;
      [moneyMovements, moneyMovementGroups] = await Promise.all([
        ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}/money_movements`, warn),
        ynabFetchOptional(baseUrl, options.token, `/plans/${options.planId}/money_movement_groups`, warn),
      ]);
    }

    const fetchedTransactions = transactions.data.transactions ?? [];
    const fetchedSubtransactions = transactions.data.subtransactions ?? flatten(fetchedTransactions, "subtransactions");
    const fetchedScheduledTransactions = fullPlan?.scheduled_transactions ?? [];
    const fetchedScheduledSubtransactions = fullPlan?.scheduled_subtransactions ?? flatten(fetchedScheduledTransactions, "subtransactions");
    const fetchedMonths = fullPlan?.months ?? [];
    const fetchedCategories = categories.data.categories ?? flatten(categories.data.category_groups ?? [], "categories");
    const rawCounts: Record<string, number> = {};
    const record = async (type: string, id: string, payload: any, knowledge?: number) => {
      await repo.upsertYnabRawObject(options.planId, type, id, payload, knowledge);
      rawCounts[type] = (rawCounts[type] ?? 0) + 1;
      await options.progress?.();
    };
    // Settings and legacy plan detail responses do not carry the cursor.
    // The mutable collection responses (or their full-export equivalents)
    // are the authoritative delta cursor set.
    const serverKnowledge = minimumServerKnowledge(accounts, categories, payees, transactions);

    if (options.minSimilarity !== undefined && options.lastKnowledgeOfServer == null) {
      const existing = await repo.listYnabTransactionFingerprints(options.planId);
      if (existing.length > 0) {
        const similarity = ynabSimilarity(existing, fetchedTransactions);
        if (similarity < options.minSimilarity) {
          await repo.finishImportSession(sessionId, "skipped", {
            reason: "similarity_below_threshold",
            similarity,
            min_similarity: options.minSimilarity,
            existing_transactions: existing.length,
            fetched_transactions: fetchedTransactions.length,
          });
          return { import_session_id: sessionId, imported_transactions: 0, skipped: true, similarity };
        }
      }
    }

    const importedPlan = plan.data.plan ?? plan.data.budget ?? { id: options.planId };
    await repo.upsertPlan(options.planId, importedPlan, settings?.data?.settings);
    await options.progress?.();

    await record("plan", String(importedPlan.id ?? options.planId), withoutArrays(importedPlan), serverKnowledge);
    if (settings?.data?.settings) await record("settings", "settings", settings.data.settings, settings.data.server_knowledge ?? serverKnowledge);

    for (const group of categories.data.category_groups ?? []) {
      await record("category_group", String(group.id), withoutArrays(group), categories.data.server_knowledge ?? serverKnowledge);
      await repo.upsertCategoryGroup(options.planId, group);
      await options.progress?.();
    }
    for (const category of fetchedCategories) {
      await record("category", String(category.id), category, categories.data.server_knowledge ?? serverKnowledge);
      await repo.upsertCategory(options.planId, category, category.category_group_id ?? findCategoryGroupId(categories.data.category_groups ?? [], category.id));
      await options.progress?.();
    }
    for (const payee of payees.data.payees ?? []) {
      await record("payee", String(payee.id), payee, payees.data.server_knowledge ?? serverKnowledge);
      await repo.upsertPayee(options.planId, payee);
      await options.progress?.();
    }
    // Transfer payees must exist before the accounts that reference them.
    for (const account of accounts.data.accounts ?? []) {
      await record("account", String(account.id), account, accounts.data.server_knowledge ?? serverKnowledge);
      await repo.upsertAccount(options.planId, account);
      await options.progress?.();
    }
    for (const location of fullPlan?.payee_locations ?? []) await record("payee_location", String(location.id), location, serverKnowledge);
    for (const month of fetchedMonths) {
      const monthId = String(month.month ?? month.id);
      await record("month", monthId, withoutArrays(month), serverKnowledge);
      for (const category of month.categories ?? []) await record("month_category", compositeId(monthId, String(category.id)), category, serverKnowledge);
    }
    for (const scheduled of fetchedScheduledTransactions) await record("scheduled_transaction", String(scheduled.id), scheduled, serverKnowledge);
    for (const subtransaction of fetchedScheduledSubtransactions) await record("scheduled_subtransaction", compositeId(String(subtransaction.scheduled_transaction_id ?? "unknown"), String(subtransaction.id)), subtransaction, serverKnowledge);
    for (const movement of moneyMovements?.data?.money_movements ?? []) await record("money_movement", String(movement.id), movement, moneyMovements?.data?.server_knowledge);
    for (const group of moneyMovementGroups?.data?.money_movement_groups ?? []) await record("money_movement_group", String(group.id), group, moneyMovementGroups?.data?.server_knowledge);

    let imported = 0;
    for (const transaction of fetchedTransactions) {
      await record("transaction", String(transaction.id), withoutArrays(transaction), transactions.data.server_knowledge ?? serverKnowledge);
      const transactionSubtransactions = fetchedSubtransactions.filter((sub: any) => sub.transaction_id === transaction.id);
      const resolvedSubtransactions = transactionSubtransactions.length ? transactionSubtransactions : transaction.subtransactions ?? [];
      for (const sub of resolvedSubtransactions) await record("subtransaction", compositeId(String(transaction.id), String(sub.id)), sub, transactions.data.server_knowledge ?? serverKnowledge);
      // YNAB data already contains both sides of every transfer. A HowMuch-local
      // capture of the same account/date/amount must be adopted, not copied.
      const existing = await repo.findYnabImportTarget(options.planId, {
        id: String(transaction.id),
        account_id: transaction.account_id,
        date: transaction.date,
        amount: transaction.amount,
        import_id: transaction.import_id,
        deleted: Boolean(transaction.deleted),
      });
      if (transaction.deleted && !existing) {
        continue;
      }
      const adoptLocal = existing != null && existing.id !== transaction.id;
      const existingSubs = Array.isArray(existing?.subtransactions) ? existing.subtransactions : [];
      const keepLocalTransfer = Boolean(adoptLocal && (existing.transfer_account_id || existing.transfer_transaction_id));
      const ynabSubtransactions = resolvedSubtransactions.map((sub: any) => ({
        id: sub.id,
        amount: sub.amount,
        payee_id: sub.payee_id,
        payee_name: sub.payee_name,
        category_id: sub.category_id,
        memo: sub.memo,
        transfer_account_id: sub.transfer_account_id,
        transfer_transaction_id: sub.transfer_transaction_id,
        external_ynab_id: sub.id,
      }));
      const subtransactions = adoptLocal && existingSubs.length ? existingSubs : ynabSubtransactions;
      await repo.createTransaction(options.planId, {
        id: existing?.id ?? transaction.id,
        account_id: transaction.account_id,
        date: transaction.date,
        amount: transaction.amount,
        deleted: transaction.deleted,
        payee_id: transaction.payee_id,
        payee_name: transaction.payee_name,
        // YNAB can retain a legacy category ID on a split parent even though
        // its categorisation lives exclusively on the split lines. Passing it
        // into the normalised resolver would create an unused synthetic
        // category, so keep it only in the raw source mirror above.
        category_id: subtransactions.length ? null : transaction.category_id,
        memo: transaction.memo,
        cleared: transaction.cleared,
        approved: transaction.approved,
        flag_color: transaction.flag_color,
        flag_name: transaction.flag_name,
        transfer_account_id: keepLocalTransfer ? existing.transfer_account_id : transaction.transfer_account_id,
        transfer_transaction_id: keepLocalTransfer ? existing.transfer_transaction_id : transaction.transfer_transaction_id,
        matched_transaction_id: transaction.matched_transaction_id,
        import_id: transaction.import_id,
        import_payee_name: transaction.import_payee_name,
        import_payee_name_original: transaction.import_payee_name_original,
        external_ynab_id: transaction.id,
        source_kind: "ynab-import",
        source_ref: sessionId,
        subtransactions,
      }, { autoLink: false });
      await repo.recordImportRow(sessionId, imported, "imported", transaction, undefined, existing?.id ?? transaction.id);
      imported += 1;
      await options.progress?.();
    }

    await repo.finishImportSession(sessionId, "completed", { imported_transactions: imported, raw_objects: rawCounts, server_knowledge: serverKnowledge });
    return { import_session_id: sessionId, imported_transactions: imported, raw_objects: rawCounts, server_knowledge: serverKnowledge };
  } catch (error) {
    await repo.finishImportSession(sessionId, "failed", { error: error instanceof Error ? error.message : String(error) });
    throw error;
  }
}

function minimumServerKnowledge(...responses: any[]): number | undefined {
  const values = responses
    .map((response) => Number(response?.data?.server_knowledge))
    .filter((value) => Number.isSafeInteger(value) && value >= 0);
  return values.length === responses.length ? Math.min(...values) : undefined;
}

export async function listYnabPlans(options: {
  token: string;
  baseUrl?: string;
  warn?: (message: string) => void;
}): Promise<YnabPlanSummary[]> {
  const baseUrl = options.baseUrl ?? DEFAULT_YNAB_BASE_URL;
  const response = await ynabFetch(baseUrl, options.token, "/plans", dedupedWarn(options.warn));
  return response.data.plans ?? response.data.budgets ?? [];
}

/** Thrown when YNAB reports the token's hourly request quota is spent. */
export class YnabRateLimitError extends Error {}

// YNAB allows 200 requests per token per rolling hour. Warn while there is
// still room to finish the current pass, not only once requests start failing.
const RATE_LIMIT_WARN_RATIO = 0.9;

/**
 * Jaccard similarity between the transactions already imported from YNAB and
 * the transactions the YNAB API just returned. A transaction on either side
 * only counts as shared when id, date, and amount all agree, so a wrong
 * budget, a truncated response, or bulk rewrites all push the score down.
 */
export function ynabSimilarity(
  existing: Array<{ external_ynab_id: string; date: string; amount_milli: number }>,
  fetched: Array<{ id: string; date: string; amount: number }>,
): number {
  const existingKeys = new Set(existing.map((row) => `${row.external_ynab_id}|${row.date}|${row.amount_milli}`));
  let shared = 0;
  for (const transaction of fetched) {
    if (existingKeys.has(`${transaction.id}|${transaction.date}|${transaction.amount}`)) {
      shared += 1;
    }
  }
  const union = existingKeys.size + fetched.length - shared;
  return union === 0 ? 1 : shared / union;
}

async function ynabFetch(
  baseUrl: string,
  token: string,
  path: string,
  warn?: (message: string) => void,
): Promise<any> {
  const response = await fetch(`${baseUrl}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  });
  const rateLimit = response.headers.get("x-rate-limit");
  if (rateLimit && warn) {
    const [used, limit] = rateLimit.split("/").map(Number);
    if (Number.isFinite(used) && Number.isFinite(limit) && limit > 0 && used / limit >= RATE_LIMIT_WARN_RATIO) {
      warn(`YNAB token has used ${used}/${limit} requests in the current hour; other apps sharing it may be starved`);
    }
  }
  if (response.status === 429) {
    throw new YnabRateLimitError(`YNAB rate limit exceeded for ${path}`);
  }
  if (!response.ok) {
    throw new Error(`YNAB fetch failed for ${path}: ${response.status}`);
  }
  return response.json();
}

/** A compatibility fallback is allowed only for an endpoint absence (404). */
async function ynabFetchOptional(
  baseUrl: string,
  token: string,
  path: string,
  warn?: (message: string) => void,
): Promise<any | null> {
  const response = await fetch(`${baseUrl}${path}`, { headers: { Authorization: `Bearer ${token}` } });
  const rateLimit = response.headers.get("x-rate-limit");
  if (rateLimit && warn) {
    const [used, limit] = rateLimit.split("/").map(Number);
    if (Number.isFinite(used) && Number.isFinite(limit) && limit > 0 && used / limit >= RATE_LIMIT_WARN_RATIO) warn(`YNAB token has used ${used}/${limit} requests in the current hour; other apps sharing it may be starved`);
  }
  if (response.status === 404) return null;
  if (response.status === 429) throw new YnabRateLimitError(`YNAB rate limit exceeded for ${path}`);
  if (!response.ok) throw new Error(`YNAB fetch failed for ${path}: ${response.status}`);
  return response.json();
}

function hasFullPlanCollections(plan: any): boolean {
  return Boolean(plan) && ["accounts", "categories", "category_groups", "payees", "months", "transactions"].some((key) => Array.isArray(plan[key]));
}

function withoutArrays(value: any): any {
  return Object.fromEntries(Object.entries(value ?? {}).filter(([, entry]) => !Array.isArray(entry)));
}

function flatten(values: any[], key: string): any[] {
  return values.flatMap((value) => Array.isArray(value?.[key]) ? value[key] : []);
}

function compositeId(parentId: string, childId: string): string {
  return `${parentId}\u001f${childId}`;
}

function findCategoryGroupId(groups: any[], categoryId: string): string | undefined {
  return groups.find((group) => Array.isArray(group.categories) && group.categories.some((category: any) => category.id === categoryId))?.id;
}

// Six parallel requests all read the same quota header; report it once.
function dedupedWarn(warn?: (message: string) => void): ((message: string) => void) | undefined {
  if (!warn) {
    return undefined;
  }
  let warned = false;
  return (message: string) => {
    if (!warned) {
      warned = true;
      warn(message);
    }
  };
}
