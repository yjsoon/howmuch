export type SqlValues = readonly unknown[];

/** Minimal asynchronous SQL surface used by D1-backed reads and writes. */
export interface AsyncSqlDatabase {
  all<Row = Record<string, unknown>>(sql: string, values?: SqlValues): Promise<Row[]>;
  get<Row = Record<string, unknown>>(sql: string, values?: SqlValues): Promise<Row | null>;
  run(sql: string, values?: SqlValues): Promise<{ rowCount: number }>;
}
