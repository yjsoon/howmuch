import type { QueryResult, QueryResultRow } from "pg";

export type SqlValues = readonly unknown[];

export interface AsyncSqlDatabase {
  all<Row extends QueryResultRow = QueryResultRow>(sql: string, values?: SqlValues): Promise<Row[]>;
  get<Row extends QueryResultRow = QueryResultRow>(sql: string, values?: SqlValues): Promise<Row | null>;
  run(sql: string, values?: SqlValues): Promise<{ rowCount: number }>;
  transaction<Result>(callback: (db: AsyncSqlDatabase) => Promise<Result>): Promise<Result>;
}

type QueryClient = {
  query<Row extends QueryResultRow = QueryResultRow>(sql: string, values?: any[]): Promise<QueryResult<Row>>;
};

/** A transaction-capable adapter shared by local pg and Worker Hyperdrive clients. */
export class PostgresDatabase implements AsyncSqlDatabase {
  private transactionDepth = 0;

  constructor(private readonly client: QueryClient) {}

  async all<Row extends QueryResultRow = QueryResultRow>(sql: string, values: SqlValues = []): Promise<Row[]> {
    return (await this.query<Row>(sql, values)).rows;
  }

  async get<Row extends QueryResultRow = QueryResultRow>(sql: string, values: SqlValues = []): Promise<Row | null> {
    return (await this.query<Row>(sql, values)).rows[0] ?? null;
  }

  async run(sql: string, values: SqlValues = []): Promise<{ rowCount: number }> {
    const result = await this.query(sql, values);
    return { rowCount: result.rowCount ?? 0 };
  }

  async transaction<Result>(callback: (db: AsyncSqlDatabase) => Promise<Result>): Promise<Result> {
    const depth = this.transactionDepth;
    const savepoint = `howmuch_${depth}`;
    await this.client.query(depth === 0 ? "BEGIN" : `SAVEPOINT ${savepoint}`);
    this.transactionDepth += 1;
    try {
      const result = await callback(this);
      this.transactionDepth -= 1;
      await this.client.query(depth === 0 ? "COMMIT" : `RELEASE SAVEPOINT ${savepoint}`);
      return result;
    } catch (error) {
      this.transactionDepth -= 1;
      await this.client.query(depth === 0 ? "ROLLBACK" : `ROLLBACK TO SAVEPOINT ${savepoint}`);
      throw error;
    }
  }

  private query<Row extends QueryResultRow = QueryResultRow>(sql: string, values: SqlValues): Promise<QueryResult<Row>> {
    return this.client.query<Row>(sql, [...values]);
  }
}
