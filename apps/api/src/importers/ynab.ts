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
};

export type YnabImportResult = {
  import_session_id: string;
  imported_transactions: number;
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
    const [plan, settings, accounts, categories, payees, transactions] = await Promise.all([
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}`, warn),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/settings`, warn),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/accounts${delta}`, warn),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/categories${delta}`, warn),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/payees${delta}`, warn),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/transactions${transactionQuery}`, warn),
    ]);

    const fetchedTransactions = transactions.data.transactions ?? [];

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

    await repo.upsertPlan(options.planId, plan.data.plan ?? plan.data.budget ?? { id: options.planId }, settings.data.settings);

    for (const account of accounts.data.accounts ?? []) {
      await repo.upsertAccount(options.planId, account);
    }

    for (const group of categories.data.category_groups ?? []) {
      await repo.upsertCategoryGroup(options.planId, group);
      for (const category of group.categories ?? []) {
        await repo.upsertCategory(options.planId, category, group.id);
      }
    }

    for (const payee of payees.data.payees ?? []) {
      await repo.upsertPayee(options.planId, payee);
    }

    let imported = 0;
    for (const transaction of fetchedTransactions) {
      // YNAB data already contains both sides of every transfer.
      await repo.createTransaction(options.planId, {
        id: transaction.id,
        account_id: transaction.account_id,
        date: transaction.date,
        amount: transaction.amount,
        deleted: transaction.deleted,
        payee_id: transaction.payee_id,
        payee_name: transaction.payee_name,
        category_id: transaction.category_id,
        memo: transaction.memo,
        cleared: transaction.cleared,
        approved: transaction.approved,
        flag_color: transaction.flag_color,
        flag_name: transaction.flag_name,
        transfer_account_id: transaction.transfer_account_id,
        transfer_transaction_id: transaction.transfer_transaction_id,
        matched_transaction_id: transaction.matched_transaction_id,
        import_id: transaction.import_id,
        import_payee_name: transaction.import_payee_name,
        import_payee_name_original: transaction.import_payee_name_original,
        external_ynab_id: transaction.id,
        source_kind: "ynab-import",
        source_ref: sessionId,
        subtransactions: (transaction.subtransactions ?? []).map((sub: any) => ({
          id: sub.id,
          amount: sub.amount,
          payee_id: sub.payee_id,
          payee_name: sub.payee_name,
          category_id: sub.category_id,
          memo: sub.memo,
          transfer_account_id: sub.transfer_account_id,
          transfer_transaction_id: sub.transfer_transaction_id,
          external_ynab_id: sub.id,
        })),
      }, { autoLink: false });
      await repo.recordImportRow(sessionId, imported, "imported", transaction, undefined, transaction.id);
      imported += 1;
    }

    const serverKnowledge = minimumServerKnowledge(accounts, categories, payees, transactions);
    await repo.finishImportSession(sessionId, "completed", { imported_transactions: imported, server_knowledge: serverKnowledge });
    return { import_session_id: sessionId, imported_transactions: imported, server_knowledge: serverKnowledge };
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
    throw new Error(`YNAB fetch failed for ${path}: ${response.status} ${await response.text()}`);
  }
  return response.json();
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
