import type { Database } from "bun:sqlite";
import type { AsyncSqlDatabase } from "./postgres";

type Row = Record<string, any>;

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
  private transactionDepth = 0;

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
      const depth = this.transactionDepth;
      const savepoint = `howmuch_${depth}`;
      this.db.run(depth === 0 ? "BEGIN IMMEDIATE" : `SAVEPOINT ${savepoint}`);
      this.transactionDepth += 1;
      try {
        const result = await callback();
        this.transactionDepth -= 1;
        this.db.run(depth === 0 ? "COMMIT" : `RELEASE SAVEPOINT ${savepoint}`);
        return result;
      } catch (error) {
        this.transactionDepth -= 1;
        this.db.run(depth === 0 ? "ROLLBACK" : `ROLLBACK TO SAVEPOINT ${savepoint}`);
        throw error;
      }
    };
  }
}

export class PostgresRepositoryDatabase implements RepositoryDatabase {
  constructor(private readonly db: AsyncSqlDatabase) {}

  query(sql: string): RepositoryStatement {
    const translated = translateSql(sql);
    return {
      get: (...values) => this.db.get(translated, values),
      all: (...values) => this.db.all(translated, values),
      run: async (...values) => ({ changes: (await this.db.run(translated, values)).rowCount }),
    };
  }

  transaction<Result>(callback: () => Promise<Result>): () => Promise<Result> {
    return () => this.db.transaction(callback);
  }
}

export function translateSql(sql: string): string {
  let parameter = 0;
  return sql
    .replace(/CURRENT_TIMESTAMP/g, "to_char(CURRENT_TIMESTAMP AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')")
    .replace(/strftime\('%Y-%m',\s*'now'\)/g, "to_char(CURRENT_TIMESTAMP AT TIME ZONE 'UTC', 'YYYY-MM')")
    .replace(/\?/g, () => `$${++parameter}`)
    .replace(/date\((\$\d+),\s*'\+1 month'\)/g, "(($1::date + INTERVAL '1 month')::date)::text");
}
