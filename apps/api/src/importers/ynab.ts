import type { LedgerRepository } from "../repository";

type YnabImportOptions = {
  token: string;
  planId: string;
  baseUrl?: string;
  sinceDate?: string;
};

export async function importYnabFromApi(
  repo: LedgerRepository,
  options: YnabImportOptions,
): Promise<{ import_session_id: string; imported_transactions: number }> {
  const baseUrl = options.baseUrl ?? "https://api.ynab.com/v1";
  const sinceDate = options.sinceDate ?? "1900-01-01";
  const sessionId = repo.createImportSession(options.planId, "ynab-api");

  try {
    const [accounts, categories, payees, transactions] = await Promise.all([
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/accounts`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/categories`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/payees`),
      ynabFetch(baseUrl, options.token, `/plans/${options.planId}/transactions?since_date=${sinceDate}`),
    ]);

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
    for (const transaction of transactions.data.transactions ?? []) {
      repo.createTransaction(options.planId, {
        id: transaction.id,
        account_id: transaction.account_id,
        date: transaction.date,
        amount: transaction.amount,
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
      });
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

