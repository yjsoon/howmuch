import { describe, expect, test } from "bun:test";
import {
  fillRegisterHorizon,
  horizonStartDate,
  REGISTER_HORIZON_MAX_ROWS,
  shouldFetchMoreForHorizon,
} from "./register-horizon";

const TODAY = "2026-08-28";
const HORIZON_START = "2026-06-28";

function row(id: string, date: string): { id: string; date: string } {
  return { id, date };
}

function page(
  transactions: { id: string; date: string }[],
  hasMore: boolean,
  nextOffset: number | null = hasMore ? 100 : null,
): { transactions: { id: string; date: string }[]; has_more: boolean; next_offset: number | null } {
  return { transactions, has_more: hasMore, next_offset: nextOffset };
}

describe("horizonStartDate", () => {
  test("shifts a pinned today back two local calendar months", () => {
    expect(horizonStartDate(TODAY)).toBe(HORIZON_START);
  });
});

describe("shouldFetchMoreForHorizon", () => {
  test("fetches the first page when the ledger is empty and more exists", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: null,
      hasMore: true,
      rowCount: 0,
      today: TODAY,
    })).toBe(true);
  });

  test("stops when a loaded date is strictly older than the horizon start", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: "2026-06-27",
      hasMore: true,
      rowCount: 10,
      today: TODAY,
    })).toBe(false);
  });

  test("keeps fetching when the oldest loaded date is the horizon start", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: HORIZON_START,
      hasMore: true,
      rowCount: 10,
      today: TODAY,
    })).toBe(true);
  });

  test("keeps fetching when every loaded date is newer than the horizon start", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: "2026-07-01",
      hasMore: true,
      rowCount: 10,
      today: TODAY,
    })).toBe(true);
  });

  test("stops at the row cap", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: "2026-07-01",
      hasMore: true,
      rowCount: REGISTER_HORIZON_MAX_ROWS,
      today: TODAY,
    })).toBe(false);
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: "2026-07-01",
      hasMore: true,
      rowCount: REGISTER_HORIZON_MAX_ROWS - 1,
      today: TODAY,
    })).toBe(true);
  });

  test("stops when the cursor is exhausted", () => {
    expect(shouldFetchMoreForHorizon({
      oldestLoadedDate: "2026-07-01",
      hasMore: false,
      rowCount: 10,
      today: TODAY,
    })).toBe(false);
  });
});

describe("fillRegisterHorizon", () => {
  test("stops after one page that already contains a date older than the start", async () => {
    const offsets: number[] = [];
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async (offset) => {
        offsets.push(offset);
        return page([row("old", "2026-05-01"), row("new", "2026-08-01")], true, 100);
      },
    });
    expect(offsets).toEqual([0]);
    expect(filled?.transactions.map((transaction) => transaction.id)).toEqual(["old", "new"]);
    expect(filled?.hasMore).toBe(true);
    expect(filled?.nextOffset).toBe(100);
  });

  test("keeps fetching a busy window of newer dates until the cursor ends", async () => {
    const offsets: number[] = [];
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async (offset) => {
        offsets.push(offset);
        if (offset === 0) return page([row("a", "2026-08-20")], true, 100);
        if (offset === 100) return page([row("b", "2026-07-15")], true, 200);
        return page([row("c", "2026-06-29")], false);
      },
    });
    expect(offsets).toEqual([0, 100, 200]);
    expect(filled?.transactions.map((transaction) => transaction.id)).toEqual(["a", "b", "c"]);
    expect(filled?.hasMore).toBe(false);
    expect(filled?.nextOffset).toBeNull();
  });

  test("stops an All-style query once a loaded date is older than the start", async () => {
    const offsets: number[] = [];
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async (offset) => {
        offsets.push(offset);
        if (offset === 0) return page([row("aug", "2026-08-10")], true, 100);
        if (offset === 100) return page([row("may", "2026-05-01")], true, 200);
        return page([row("apr", "2026-04-01")], true, 300);
      },
    });
    expect(offsets).toEqual([0, 100]);
    expect(filled?.transactions.map((transaction) => transaction.id)).toEqual(["aug", "may"]);
    expect(filled?.hasMore).toBe(true);
    expect(filled?.nextOffset).toBe(200);
  });

  test("stops at the 600-row cap", async () => {
    const offsets: number[] = [];
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async (offset) => {
        offsets.push(offset);
        const start = offset;
        return page(
          Array.from({ length: 100 }, (_, index) => row(`r${start + index}`, "2026-08-01")),
          true,
          offset + 100,
        );
      },
    });
    expect(offsets).toEqual([0, 100, 200, 300, 400, 500]);
    expect(filled?.transactions).toHaveLength(REGISTER_HORIZON_MAX_ROWS);
    expect(filled?.hasMore).toBe(true);
    expect(filled?.nextOffset).toBe(600);
  });

  test("returns null when a later isCurrent check fails", async () => {
    let checks = 0;
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => {
        checks += 1;
        return checks === 1;
      },
      fetchPage: async (offset) => page([row(`p${offset}`, "2026-08-01")], true, offset + 100),
    });
    expect(filled).toBeNull();
  });

  test("keeps the partial ledger and the load-older bar when a later page fails", async () => {
    const filled = await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async (offset) => {
        if (offset === 0) return page([row("first", "2026-08-01")], true, 100);
        throw new Error("page 1 failed");
      },
    });
    expect(filled?.transactions.map((transaction) => transaction.id)).toEqual(["first"]);
    expect(filled?.hasMore).toBe(true);
    expect(filled?.nextOffset).toBe(100);
  });

  test("reports each committed page so the register can paint before the fill ends", async () => {
    const progress: Array<{ ids: string[]; done: boolean }> = [];
    await fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      onProgress: (update) => {
        progress.push({ ids: update.transactions.map((transaction) => transaction.id), done: update.done });
      },
      fetchPage: async (offset) => {
        if (offset === 0) return page([row("a", "2026-08-20")], true, 100);
        return page([row("b", "2026-05-01")], true, 200);
      },
    });
    expect(progress).toEqual([
      { ids: ["a"], done: false },
      { ids: ["a", "b"], done: true },
    ]);
  });

  test("throws when page 0 fails", async () => {
    await expect(fillRegisterHorizon({
      today: TODAY,
      isCurrent: () => true,
      fetchPage: async () => {
        throw new Error("page 0 failed");
      },
    })).rejects.toThrow("page 0 failed");
  });

  test("keeps fetching when the focused account's oldest loaded date is still inside the horizon", async () => {
    const TODAY_SEP = "2026-09-01";
    type Row = { id: string; date: string; account_id: string };
    const row = (id: string, date: string, account_id: string): Row => ({ id, date, account_id });
    const offsets: number[] = [];
    const filled = await fillRegisterHorizon({
      today: TODAY_SEP,
      accountId: "joey",
      isCurrent: () => true,
      fetchPage: async (offset) => {
        offsets.push(offset);
        if (offset === 0) {
          return {
            transactions: [
              row("future", "2026-09-08", "joey"),
              row("other-aug", "2026-08-20", "other"),
              row("grab", "2026-08-29", "joey"),
              row("other-june", "2026-06-15", "other"),
            ],
            has_more: true,
            next_offset: 100,
          };
        }
        return {
          transactions: [row("july-groceries", "2026-07-20", "joey")],
          has_more: true,
          next_offset: 200,
        };
      },
    });
    expect(offsets).toEqual([0, 100]);
    expect(filled?.transactions.map((transaction) => transaction.id)).toEqual([
      "future",
      "other-aug",
      "grab",
      "other-june",
      "july-groceries",
    ]);
  });
});
