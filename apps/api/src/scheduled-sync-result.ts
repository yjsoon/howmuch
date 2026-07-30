import type { YnabImportResult } from "./importers/ynab";

export type ScheduledSyncResult =
  | { status: "completed"; run_id: string; result: YnabImportResult }
  | { status: "duplicate" | "leased" | "skipped"; run_id: string; result?: YnabImportResult };
