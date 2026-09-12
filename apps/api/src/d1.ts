import type { AsyncSqlDatabase, SqlValues } from "./async-sql";
import type { BatchStatement, RepositoryDatabase, RepositoryStatement } from "./repository-db";

export type D1Result<Row = Record<string, unknown>> = {
  results?: Row[];
  success: boolean;
  meta?: { changes?: number };
};

export interface D1Statement {
  bind(...values: unknown[]): D1Statement;
  all<Row = Record<string, unknown>>(): Promise<D1Result<Row>>;
  first<Row = Record<string, unknown>>(): Promise<Row | null>;
  run(): Promise<D1Result>;
}

export interface D1Binding {
  prepare(sql: string): D1Statement;
  batch<Row = Record<string, unknown>>(statements: D1Statement[]): Promise<D1Result<Row>[]>;
}

/**
 * Thin D1 adapter for individual statements and Cloudflare's atomic batch API.
 * D1 cannot hold an interactive transaction across awaits, so transaction()
 * deliberately fails rather than giving callers false atomicity.
 */
export class D1Database implements AsyncSqlDatabase, RepositoryDatabase {
  constructor(readonly binding: D1Binding) {}

  query(sql: string): RepositoryStatement {
    const translated = d1Sql(sql);
    return {
      get: async (...values) => (await this.statement(translated, values).first()) as Record<string, any> | null,
      all: async (...values) => ((await this.statement(translated, values).all()).results ?? []) as Record<string, any>[],
      run: async (...values) => ({ changes: Number((await this.statement(translated, values).run()).meta?.changes ?? 0) }),
    };
  }

  async all<Row = Record<string, unknown>>(sql: string, values: SqlValues = []): Promise<Row[]> {
    const prepared = prepareNumberedSql(sql, values);
    return ((await this.statement(prepared.sql, prepared.values).all<Row>()).results ?? []);
  }

  async get<Row = Record<string, unknown>>(sql: string, values: SqlValues = []): Promise<Row | null> {
    const prepared = prepareNumberedSql(sql, values);
    return this.statement(prepared.sql, prepared.values).first<Row>();
  }

  async run(sql: string, values: SqlValues = []): Promise<{ rowCount: number }> {
    const prepared = prepareNumberedSql(sql, values);
    return { rowCount: Number((await this.statement(prepared.sql, prepared.values).run()).meta?.changes ?? 0) };
  }

  /**
   * Batched reads: one Worker-to-D1 round trip for the whole list. D1 runs a
   * batch as a single transaction, so every statement observes one snapshot.
   */
  async batchRead(statements: BatchStatement[]): Promise<Record<string, any>[][]> {
    if (statements.length === 0) return [];
    // Deliberately not via atomicBatch(): the two are separate entry points so
    // a wrapper can instrument either without the other counting twice.
    const results = await this.sendBatch(statements);
    return results.map((result) => (result.results ?? []) as Record<string, any>[]);
  }

  transaction<Result>(_callback: ((db: AsyncSqlDatabase) => Promise<Result>) | (() => Promise<Result>)): never {
    throw new Error("D1 does not support interactive transactions; use D1Database.atomicBatch() with a complete, preplanned statement list");
  }

  atomicBatch<Row = Record<string, unknown>>(statements: Array<{ sql: string; values?: SqlValues }>): Promise<D1Result<Row>[]> {
    if (statements.length === 0) return Promise.resolve([]);
    return this.sendBatch<Row>(statements);
  }

  /** One binding.batch call: one round trip, run as a single transaction. */
  private sendBatch<Row = Record<string, unknown>>(
    statements: Array<{ sql: string; values?: SqlValues }>,
  ): Promise<D1Result<Row>[]> {
    return this.binding.batch<Row>(statements.map(({ sql, values = [] }) => {
      const prepared = prepareNumberedSql(sql, values);
      return this.statement(prepared.sql, prepared.values);
    }));
  }

  private statement(sql: string, values: SqlValues): D1Statement {
    const statement = this.binding.prepare(d1Sql(sql));
    return values.length ? statement.bind(...values) : statement;
  }
}

function prepareNumberedSql(sql: string, values: SqlValues): { sql: string; values: unknown[] } {
  const reordered: unknown[] = [];
  const translated = sql.replace(/\$(\d+)/g, (_match, index) => {
    reordered.push(values[Number(index) - 1]);
    return "?";
  });
  return { sql: translated, values: reordered.length ? reordered : [...values] };
}

function d1Sql(sql: string): string {
  return sql
    .replace(/::jsonb/g, "")
    .replace(/GREATEST\(([^,]+),\s*([^\)]+)\)/gi, "MAX($1, $2)")
    .replace(/left\(([^,]+),\s*(\d+)\)/gi, "substr($1, 1, $2)");
}
