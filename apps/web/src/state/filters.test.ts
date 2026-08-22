import { describe, expect, test } from "bun:test";
import { applyFilterPatch, filtersFromSearch } from "./filters";

describe("applyFilterPatch", () => {
  test("writes empty account and category selections instead of ignoring them", () => {
    const previous = new URLSearchParams("accounts=acc-1&categories=cat-1&from=2026-08-01&to=2026-08-31");
    const next = applyFilterPatch(previous, { accountIds: [], categoryIds: [] });
    expect(next.get("accounts")).toBe("all");
    expect(next.get("categories")).toBeNull();
    expect(next.get("from")).toBe("2026-08-01");
  });

  test("marks a cleared date range as explicit all-time", () => {
    const next = applyFilterPatch(new URLSearchParams("from=2026-08-01&to=2026-08-31"), {
      from: undefined,
      to: undefined,
    });
    expect(next.get("from")).toBeNull();
    expect(next.get("to")).toBeNull();
    expect(next.get("range")).toBe("all");
  });
});

describe("filtersFromSearch", () => {
  test("treats accounts=all as a deliberate empty selection", () => {
    const filters = filtersFromSearch(new URLSearchParams("accounts=all"), {
      defaultRange: () => ({ from: "2026-08-01", to: "2026-08-31" }),
      prefs: { accountIds: ["remembered"] },
    });
    expect(filters.accountIds).toEqual([]);
    expect(filters.from).toBe("2026-08-01");
  });

  test("falls back to remembered accounts only when the URL omits them", () => {
    const filters = filtersFromSearch(new URLSearchParams(), {
      defaultRange: () => ({}),
      prefs: { accountIds: ["remembered"], interval: "week" },
    });
    expect(filters.accountIds).toEqual(["remembered"]);
    expect(filters.interval).toBe("week");
  });
});
