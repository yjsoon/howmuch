import type { LedgerRepository } from "../repository";
import { csvRowToMilliunits } from "../money";

export type CsvImportRow = {
  date: string;
  payee?: string;
  payee_name?: string;
  memo?: string;
  outflow?: string;
  inflow?: string;
  amount?: string;
  category_id?: string | null;
};

export function importCsvRows(
  repo: LedgerRepository,
  planId: string,
  accountId: string,
  rows: CsvImportRow[],
): { import_session_id: string; imported: number; failed: number } {
  const sessionId = repo.createImportSession(planId, "csv");
  let imported = 0;
  let failed = 0;

  rows.forEach((row, index) => {
    try {
      const amount = csvRowToMilliunits(row);
      const transaction = repo.createTransaction(planId, {
        account_id: accountId,
        date: row.date,
        amount,
        payee_name: row.payee_name ?? row.payee ?? null,
        memo: row.memo ?? null,
        category_id: row.category_id ?? null,
        source_kind: "csv",
        source_ref: sessionId,
      });
      repo.recordImportRow(sessionId, index, "imported", row, undefined, transaction.id);
      imported += 1;
    } catch (error) {
      failed += 1;
      repo.recordImportRow(sessionId, index, "failed", row, error instanceof Error ? error.message : String(error));
    }
  });

  repo.finishImportSession(sessionId, failed > 0 ? "completed_with_errors" : "completed", { imported, failed });
  return { import_session_id: sessionId, imported, failed };
}

