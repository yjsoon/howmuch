import { csvRowToMilliunits } from "../money";
import type { LedgerStore } from "../storage";

export type CsvImportRow = {
  date: string;
  account_id?: string;
  payee_id?: string | null;
  payee?: string;
  payee_name?: string;
  memo?: string;
  outflow?: string;
  inflow?: string;
  amount?: string;
  import_id?: string | null;
  category_id?: string | null;
  cleared?: "cleared" | "uncleared" | "reconciled" | null;
  approved?: boolean | null;
  flag_color?: string | null;
  flag_name?: string | null;
};

export async function importCsvRows(
  repo: LedgerStore,
  planId: string,
  accountId: string,
  rows: CsvImportRow[],
): Promise<{ import_session_id: string; imported: number; duplicate: number; failed: number }> {
  const sessionId = await repo.createImportSession(planId, "csv");
  let imported = 0;
  let duplicate = 0;
  let failed = 0;

  for (const [index, row] of rows.entries()) {
    try {
      const resolvedAccountId = row.account_id ?? accountId;
      if (!resolvedAccountId) {
        throw new Error("account_id is required for CSV import rows");
      }
      const amount = csvRowToMilliunits(row);
      const input = {
        account_id: resolvedAccountId,
        date: row.date,
        amount,
        payee_id: row.payee_id ?? null,
        payee_name: row.payee_name ?? row.payee ?? null,
        memo: row.memo ?? null,
        import_id: row.import_id ?? null,
        category_id: row.category_id ?? null,
        cleared: row.cleared ?? "uncleared",
        approved: row.approved ?? true,
        flag_color: row.flag_color ?? null,
        flag_name: row.flag_name ?? null,
        source_kind: "csv",
        source_ref: sessionId,
      } as const;
      const existing = await repo.findDuplicateTransaction(planId, input);
      if (existing) {
        await repo.recordImportRow(sessionId, index, "duplicate", row, undefined, existing.id);
        duplicate += 1;
        continue;
      }

      // Bank feeds carry each side separately; never mirror on import.
      const transaction = await repo.createTransaction(planId, input, { autoLink: false });
      await repo.recordImportRow(sessionId, index, "imported", row, undefined, transaction.id);
      imported += 1;
    } catch (error) {
      failed += 1;
      await repo.recordImportRow(sessionId, index, "failed", row, error instanceof Error ? error.message : String(error));
    }
  }

  await repo.finishImportSession(sessionId, failed > 0 ? "completed_with_errors" : "completed", { imported, duplicate, failed });
  return { import_session_id: sessionId, imported, duplicate, failed };
}
