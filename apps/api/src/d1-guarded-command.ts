import { createHash } from "node:crypto";
import type { D1Database } from "./d1";
import type { SqlValues } from "./async-sql";
import type { D1WriteContext, PlannedStatement } from "./d1-transaction-repository";

export type GuardedCommand = Readonly<{
  kind: string;
  planId: string;
  resourceId: string;
  payload: unknown;
  context?: D1WriteContext;
  statements: readonly PlannedStatement[];
}>;

/** Executes one immutable write_commands/write_state guarded D1 batch. */
export class D1GuardedCommandExecutor {
  constructor(private readonly db: D1Database, private readonly maxStaleRetries = 3) {}

  async execute<Result>(command: GuardedCommand, readResult: () => Promise<Result>): Promise<Result> {
    const commandId = command.context?.operationId ?? crypto.randomUUID();
    if (!commandId) throw new Error("operationId is required");
    if (command.context?.lease && command.context.lease.planId !== command.planId) throw new Error("Scheduler lease plan does not match command plan");
    const hash = requestHash(command.payload);
    for (let attempt = 0; attempt <= this.maxStaleRetries; attempt++) {
      if (await this.replayed(commandId, command, hash)) return readResult();
      const state = await this.db.get<{ write_version: number }>("SELECT write_version FROM write_state WHERE singleton=1");
      if (!state) throw new Error("D1 write_state is not initialized");
      const lease = command.context?.lease;
      const statements = [
        statement("INSERT INTO write_commands (id,expected_write_version,kind,plan_id,transaction_id,request_hash,result_json,lease_plan_id,lease_attempt_id) VALUES (?,?,?,?,?,?,?,?,?)", [commandId, Number(state.write_version), command.kind, command.planId, command.resourceId, hash, JSON.stringify({ resourceId: command.resourceId }), lease?.planId ?? null, lease?.attemptId ?? null]),
        ...command.statements,
        statement("UPDATE write_state SET write_version=write_version+1,last_command_id=? WHERE singleton=1", [commandId]),
        statement("UPDATE write_commands SET status='applied',applied_at=CURRENT_TIMESTAMP WHERE id=?", [commandId]),
      ];
      try {
        await this.db.atomicBatch(statements.map((item) => ({ sql: item.sql, values: [...item.values] })));
        return readResult();
      } catch (error) {
        if (await this.replayed(commandId, command, hash)) return readResult();
        if (!String(error).includes("stale write command") || attempt === this.maxStaleRetries) throw error;
      }
    }
    throw new Error(`Unable to apply ${command.kind}`);
  }

  private async replayed(id: string, command: GuardedCommand, hash: string): Promise<boolean> {
    const row = await this.db.get<Record<string, any>>("SELECT kind,plan_id,transaction_id,request_hash,lease_plan_id,lease_attempt_id,status FROM write_commands WHERE id=?", [id]);
    if (!row) return false;
    const lease = command.context?.lease;
    if (row.kind !== command.kind || row.plan_id !== command.planId || row.transaction_id !== command.resourceId || row.request_hash !== hash || row.lease_plan_id !== (lease?.planId ?? null) || row.lease_attempt_id !== (lease?.attemptId ?? null)) throw new Error("idempotency-key reuse");
    return row.status === "applied";
  }
}

export function statement(sql: string, values: SqlValues = []): PlannedStatement {
  return Object.freeze({ sql, values: Object.freeze([...values]) });
}

export function requestHash(value: unknown): string {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

function canonicalJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value as Record<string, unknown>).filter((key) => (value as any)[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson((value as any)[key])}`).join(",")}}`;
}
