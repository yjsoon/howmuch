import { describe, expect, test } from "bun:test";
import { compileTermsDraft, parseStatementRows, statementCsv } from "./reward-tools-contract";
import { SimpleRewardsCalculator } from "./rewards/engine/simple-calculator";
import type { CreditCard } from "./rewards/types";

const baseCard: CreditCard = { id: "card", name: "Card", issuer: "Bank", type: "cashback", ynabAccountId: "account", featured: false, earningRate: 1 };
function calculate(card: CreditCard, spends: Array<[string, number]>) {
  return SimpleRewardsCalculator.calculateCardRewards(card, spends.map(([flag_color, dollars], i) => ({
    id: String(i), date: "2026-02-09", amount: -dollars * 1000, account_id: "account", flag_color,
  })), { start: "2026-02-01", end: "2026-02-28", label: "2026-02" });
}

describe("reward tools contracts", () => {
  test("unknown matched category limits survive and explicit zero replaces them", () => {
    const previous = { ...baseCard, ...compileTermsDraft(JSON.stringify({ buckets: [{ name: "Dining", rewardValue: 4, minimumSpend: 73, maximumSpend: 137, milesBlockSize: 11 }] }), {}).patch };
    for (const unknown of [{}, { minimumSpend: null, maximumSpend: null, milesBlockSize: null }]) {
      const card = { ...previous, ...compileTermsDraft(JSON.stringify({ buckets: [{ name: " dining ", rewardValue: 4, ...unknown }] }), previous).patch };
      expect(card.subcategories[0]).toMatchObject({ minimumSpend: 73, maximumSpend: 137, milesBlockSize: 11 });
      expect(calculate(card, [[card.subcategories[0].flagColor, 50]]).rewardEarned).toBe(0);
      expect(calculate({ ...card, type: "miles" }, [[card.subcategories[0].flagColor, 200]]).rewardEarned).toBe(528);
    }
    const patch = compileTermsDraft(JSON.stringify({ buckets: [{ name: "Dining", rewardValue: 4, minimumSpend: 0, maximumSpend: 0 }] }), previous).patch;
    expect(patch.subcategories[0]).toMatchObject({ minimumSpend: 0, maximumSpend: 0, milesBlockSize: 11 });
  });
  test("omitted default uses proposed base only when no existing default exists", () => {
    const draft = JSON.stringify({ buckets: [{ name: "Dining", rewardValue: 4 }], cardLimits: { earningRate: 2 } });
    expect(calculate({ ...baseCard, ...compileTermsDraft(draft, baseCard).patch }, [["unflagged", 100]]).rewardEarned).toBe(2);
    const previous = { ...baseCard, ...compileTermsDraft(JSON.stringify({ buckets: [{ name: "Other", rewardValue: 3, minimumSpend: 17, maximumSpend: 137, milesBlockSize: 11 }] }), {}).patch };
    const card = { ...previous, ...compileTermsDraft(draft, previous).patch };
    expect(card.subcategories.at(-1)).toMatchObject({ rewardValue: 3, minimumSpend: 17, maximumSpend: 137, milesBlockSize: 11 });
    expect(calculate(card, [["unflagged", 100]]).rewardEarned).toBe(3);
    const renamed = compileTermsDraft(JSON.stringify({ buckets: [{ name: "Default", rewardValue: 2 }] }), previous).patch;
    expect(renamed.subcategories[0]).toMatchObject({ id: previous.subcategories[0].id, minimumSpend: 17, maximumSpend: 137, milesBlockSize: 11 });
    for (const earningRate of [null, 0, 5]) {
      const tiered = { ...previous, ...compileTermsDraft(JSON.stringify({ buckets: [{ name: "Other", rewardValue: 3 }], spendingTiers: [{ spendThreshold: 500, earningRate }] }), previous).patch };
      expect(calculate(tiered, [["unflagged", 1000]]).rewardEarned).toBeCloseTo(137 * (earningRate ?? 3) / 100);
    }
  });
  test("tier base rate applies to default, not named rates; explicit overrides relink by name", () => {
    const buckets = [{ name: "Dining", rewardValue: 4 }, { name: "Excluded", rewardValue: 9, excludeFromRewards: true }, { name: "Everything else", rewardValue: 1 }];
    const compile = (subcategories?: unknown[]) => ({ ...baseCard, ...compileTermsDraft(JSON.stringify({ buckets, spendingTiers: [{ spendThreshold: 500, earningRate: 5, subcategories }] }), {}).patch });
    expect(calculate(compile(), [["unflagged", 1000]]).rewardEarned).toBe(50);
    expect(calculate(compile(), [["red", 1000]]).rewardEarned).toBe(40);
    const card = compile([{ name: " dining ", rewardValue: 7, maximumSpend: 137 }, { name: "Excluded", rewardValue: 12, maximumSpend: 0 }, { name: "Everything else", rewardValue: 0, maximumSpend: null }]);
    expect(card.spendingTiers?.[0].subcategories).toEqual(card.subcategories.map((s, i) => ({ subcategoryId: s.id, rewardValue: [7, 12, 0][i], maximumSpend: [137, 0, null][i] })));
    expect(calculate(card, [["red", 1000], ["orange", 1000], ["unflagged", 1000]]).rewardEarned).toBeCloseTo(9.59);
    expect(calculate({ ...card, subcategories: card.subcategories.map((s) => s.name === "Dining" ? { ...s, active: false } : s) }, [["red", 1000], ["orange", 1000]]).rewardEarned).toBe(0);
    for (const overrides of [[{ name: "Missing", rewardValue: 2 }], [{ name: "Dining", rewardValue: 2 }, { name: " dining ", rewardValue: 3 }], [{ name: "Dining", rewardValue: -1 }]]) expect(() => compile(overrides)).toThrow();
  });
  for (const level of ["category", "card"] as const) {
    test(`${level} treats zero maximum spend as unlimited while rejecting a positive cap below minimum`, () => {
      const draft = (maximumSpend: number) => JSON.stringify({
        buckets: [{ name: "Dining", rewardValue: 4, ...(level === "category" ? { minimumSpend: 500, maximumSpend } : {}) }],
        ...(level === "card" ? { cardLimits: { minimumSpend: 500, maximumSpend } } : {}),
      });
      for (const maximumSpend of [0, 500, 750]) {
        const { patch } = compileTermsDraft(draft(maximumSpend), {});
        expect(level === "category" ? patch.subcategories[0] : patch).toMatchObject({ minimumSpend: 500, maximumSpend });
      }
      expect(() => compileTermsDraft(draft(499), {})).toThrow();
    });
  }
  test("rejects malformed dates, conflicting flows and invalid amounts", () => {
    const row = { date: "2026-02-28", payee: "Shop", memo: "", outflow: "12.30", inflow: "" };
    expect(parseStatementRows(JSON.stringify([row]))).toEqual([row]);
    for (const change of [{ date: "2026-02-30" }, { inflow: "2.00" }, { outflow: "=1+2" }]) {
      expect(() => parseStatementRows(JSON.stringify([{ ...row, ...change }]))).toThrow();
    }
  });
  test("CSV has exact headers, quotes newlines and neutralizes formulas after whitespace", () => {
    expect(statementCsv([{ date: "2026-01-02", payee: ' \t=HYPERLINK("x")', memo: "a,b\nc", outflow: "9.20", inflow: "" }]))
      .toBe('Date,Payee,Memo,Outflow,Inflow\r\n2026-01-02,"\' \t=HYPERLINK(""x"")","a,b\nc",9.20,\r\n');
  });
  test("per-image row cap does not prevent exporting combined images", () => {
    const rows = Array.from({ length: 2001 }, () => ({ date: "2026-09-01", payee: "Shop", memo: "", outflow: "1.23", inflow: "" }));
    expect(() => parseStatementRows(JSON.stringify(rows))).toThrow();
    expect(statementCsv(rows).split("\r\n").length).toBe(2003);
  });
  test("preserves matching IDs and flags, retains tier overrides, excludes rewards", () => {
    const previous = [{ id: "old", name: "Dining", flagColor: "blue", createdAt: "before" }];
    const result = compileTermsDraft(JSON.stringify({ buckets: [
      { name: " dining ", rewardValue: 4, inclusion: "Selected restaurants only" },
      { name: "Excluded", rewardValue: 9, excludeFromRewards: true },
    ] }), { subcategories: previous, spendingTiers: [{ id: "tier", spendThreshold: 100, subcategories: [{ subcategoryId: "old", rewardValue: 6 }, { subcategoryId: "removed", rewardValue: 8 }] }], earningRate: 1 });
    expect(result.patch.subcategories[0]).toMatchObject({ id: "old", flagColor: "blue", createdAt: "before" });
    expect(result.patch.subcategories[1].rewardValue).toBe(0);
    expect(result.patch.subcategories[2]).toMatchObject({ flagColor: "unflagged", rewardValue: 1 });
    expect(result.patch.spendingTiers?.[0].subcategories).toEqual([{ subcategoryId: "old", rewardValue: 6 }]);
    expect(result.notes.join(" ")).toContain("Selected restaurants only");
  });
  test("rejects invalid limits, duplicate categories, and excess colors rather than silently discarding", () => {
    for (const input of [
      { buckets: [{ name: "Dining", rewardValue: -1 }] },
      { buckets: [{ name: "Dining", rewardValue: 1 }, { name: "dining", rewardValue: 2 }] },
      { buckets: Array.from({ length: 7 }, (_, i) => ({ name: `Category ${i}`, rewardValue: 1 })) },
      { buckets: [{ name: "Dining", rewardValue: 1 }], cardLimits: { earningBlockSize: 0 } },
    ]) expect(() => compileTermsDraft(JSON.stringify(input), {})).toThrow();
  });
  test("a previously unflagged named category cannot donate its ID twice", () => {
    const result = compileTermsDraft(JSON.stringify({ buckets: [{ name: "Dining", rewardValue: 4 }] }), { subcategories: [{ id: "old", name: "Dining", flagColor: "unflagged" }] });
    expect(result.patch.subcategories[0].id).toBe("old");
    expect(new Set(result.patch.subcategories.map((c) => c.id)).size).toBe(2);
  });
  test("supports all six colors plus default, reserves matching colors, compiles sorted tiers and blocks", () => {
    const result = compileTermsDraft(JSON.stringify({
      buckets: ["New", "Dining", "Travel", "Groceries", "Online", "Excluded"].map((name) => ({ name, rewardValue: 4, milesBlockSize: 5 })),
      cardLimits: { earningBlockSize: 10, maximumSpend: 2400 },
      spendingTiers: [{ spendThreshold: 1000, earningRate: 6, maximumSpend: 2000 }, { spendThreshold: 500, earningRate: 4 }],
    }), { subcategories: [{ id: "dining", name: "Dining", flagColor: "red" }] });
    expect(result.patch.subcategories.map((c) => c.flagColor)).toEqual(["orange", "red", "yellow", "green", "blue", "purple", "unflagged"]);
    expect(result.patch.subcategories[1]).toMatchObject({ id: "dining", milesBlockSize: 5 });
    expect(result.patch).toMatchObject({ earningBlockSize: 10, maximumSpend: 2400 });
    expect(result.patch.spendingTiers?.map((t) => [t.spendThreshold, t.earningRate, t.maximumSpend])).toEqual([[500, 4, null], [1000, 6, 2000]]);
  });
});
