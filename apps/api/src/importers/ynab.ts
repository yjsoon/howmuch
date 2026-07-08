import type { LedgerRepository } from "../repository";

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
};

export type YnabImportResult = {
  import_session_id: string;
  imported_transactions: number;
  skipped?: boolean;
  similarity?: number;
};

export type YnabPlanSummary = {
  id: string;
  name: string;
  last_modified_on?: string;
};

const DEFAULT_YNAB_BASE_URL = "https://api.ynab.com/v1";

export async function importYnabFromApi(
  repo: LedgerRepository,
  options: YnabImportOptions,
): Promise<YnabImportResult> {
  const baseUrl = options.baseUrl ?? DEFAULT_YNAB_BASE_URL;
  const sinceDate = options.sinceDate ?? "1900-01-01";
  const sessionId = repo.createImportSession(options.planId, "ynab-api");

  try {
    const [plan, settings, accounts, categories, payees, transactions] = await Promise.all([
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/settings`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/accounts`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/categories`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/payees`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/transactions?since_date=${sinceDate}`),
    ]);

    const fetchedTransactions = transactions.data.transactions ?? [];

    if (options.minSimilarity !== undefined) {
      const existing = repo.listYnabTransactionFingerprints(options.planId);
      if (existing.length > 0) {
        const similarity = ynabSimilarity(existing, fetchedTransactions);
        if (similarity < options.minSimilarity) {
          repo.finishImportSession(sessionId, "skipped", {
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

    repo.upsertPlan(options.planId, plan.data.plan ?? plan.data.budget ?? { id: options.planId }, settings.data.settings);

    for (const account of accounts.data.accounts ?? []) {
      repo.upsertAccount(options.planId, account);
    }

    for (const group of categories.data.category_groups ?? []) {
      repo.upsertCategoryGroup(options.planId, group);
      for (const category of group.categories ?? []) {
        repo.upsertCategory(options.planId, category, group.id);
      }
    }

    for (const payee of payees.data.payees ?? []) {
      repo.upsertPayee(options.planId, payee);
    }

    let imported = 0;
    for (const transaction of fetchedTransactions) {
      // YNAB data already contains both sides of every transfer.
      repo.createTransaction(options.planId, {
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
      repo.recordImportRow(sessionId, imported, "imported", transaction, undefined, transaction.id);
      imported += 1;
    }

    repo.finishImportSession(sessionId, "completed", { imported_transactions: imported });
    return { import_session_id: sessionId, imported_transactions: imported };
  } catch (error) {
    repo.finishImportSession(sessionId, "failed", { error: error instanceof Error ? error.message : String(error) });
    throw error;
  }
}

export async function listYnabPlans(options: {
  token: string;
  baseUrl?: string;
}): Promise<YnabPlanSummary[]> {
  const baseUrl = options.baseUrl ?? DEFAULT_YNAB_BASE_URL;
  const response = await ynabFetch(baseUrl, options.token, "/plans");
  return response.data.plans ?? response.data.budgets ?? [];
}

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

async function ynabFetch(baseUrl: string, token: string, path: string): Promise<any> {
  const response = await fetch(`${baseUrl}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  });
  if (!response.ok) {
    throw new Error(`YNAB fetch failed for ${path}: ${response.status} ${await response.text()}`);
  }
  return response.json();
}
