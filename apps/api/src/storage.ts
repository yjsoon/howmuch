import type { LedgerRepository } from "./repository";
import type { ReportService } from "./reports";

export type Awaitable<T> = T | Promise<T>;

/**
 * Public storage boundary used by HTTP, import, and scheduled-sync code.
 * SQLite satisfies it synchronously today; asynchronous D1 implementations
 * return promises. Callers must always await it so runtime choice is invisible.
 */
export type AwaitableMethods<T> = {
  [Key in keyof T]: T[Key] extends (...args: infer Args) => infer Result
    ? (...args: Args) => Awaitable<Awaited<Result>>
    : T[Key];
};

export type LedgerStore = AwaitableMethods<LedgerRepository>;
export type ReportStore = AwaitableMethods<ReportService>;
