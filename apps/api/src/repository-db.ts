import type { Database } from "bun:sqlite";

type Row = Record<string, any>;
const sqliteTransactionTails = new WeakMap<Database, Promise<void>>();

/** One statement in a batched read, with its positional bindings. */
export type BatchStatement = { sql: string; values?: readonly any[] };

export type RepositoryStatement = {
  get(...values: any[]): Promise<Row | null>;
  all(...values: any[]): Promise<Row[]>;
  run(...values: any[]): Promise<{ changes: number }>;
};

export interface RepositoryDatabase {
  query(sql: string): RepositoryStatement;
  transaction<Result>(callback: () => Promise<Result>): () => Promise<Result>;
  /**
   * Runs several read statements as one round trip, inside one transaction, and
   * returns their row sets in order. Callers rely on every statement seeing the
   * same snapshot — that is what lets a page query and the `server_knowledge`
   * it is labelled with come back consistent without a second read.
   */
  batchRead(statements: BatchStatement[]): Promise<Row[][]>;
}

export class SqliteRepositoryDatabase implements RepositoryDatabase {
  constructor(private readonly db: Database) {}

  query(sql: string): RepositoryStatement {
    const statement = this.db.query(sql);
    return {
      get: async (...values) => (statement.get(...values) as Row | null) ?? null,
      all: async (...values) => statement.all(...values) as Row[],
      run: async (...values) => {
        const result = statement.run(...values);
        return { changes: Number(result.changes) };
      },
    };
  }

  async batchRead(statements: BatchStatement[]): Promise<Row[][]> {
    if (statements.length === 0) return [];
    const run = () => statements.map(({ sql, values = [] }) => this.db.query(sql).all(...(values as any[])) as Row[]);
    // bun:sqlite is synchronous, so the statements above already share a
    // snapshot. BEGIN makes that explicit and matches what D1's batch gives
    // remotely. Reuse an open transaction rather than queueing behind it: the
    // transaction() serialiser would otherwise deadlock waiting on the caller.
    if (this.db.inTransaction) return run();
    return this.transaction(async () => run())();
  }

  transaction<Result>(callback: () => Promise<Result>): () => Promise<Result> {
    return async () => {
      const previous = sqliteTransactionTails.get(this.db) ?? Promise.resolve();
      let release!: () => void;
      sqliteTransactionTails.set(this.db, new Promise<void>((resolve) => { release = resolve; }));
      await previous;
      let began = false;
      try {
        this.db.run("BEGIN IMMEDIATE");
        began = true;
        const result = await callback();
        this.db.run("COMMIT");
        return result;
      } catch (error) {
        if (began && this.db.inTransaction) this.db.run("ROLLBACK");
        throw error;
      } finally {
        release();
      }
    };
  }
}
