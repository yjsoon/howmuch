import type { Database } from "bun:sqlite";

type Row = Record<string, any>;
const sqliteTransactionTails = new WeakMap<Database, Promise<void>>();

export type RepositoryStatement = {
  get(...values: any[]): Promise<Row | null>;
  all(...values: any[]): Promise<Row[]>;
  run(...values: any[]): Promise<{ changes: number }>;
};

export interface RepositoryDatabase {
  query(sql: string): RepositoryStatement;
  transaction<Result>(callback: () => Promise<Result>): () => Promise<Result>;
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
