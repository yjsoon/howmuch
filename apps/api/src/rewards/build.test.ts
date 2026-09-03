import { expect, test } from "bun:test";
import officialExport from "../../../../fixtures/rewards-tracker-export.json";
import { buildRewardsReport } from "./build";
import { parseAppSettings, parseCreditCards } from "./parse";
import type { Transaction } from "./types";

const cards = parseCreditCards(officialExport.cards);
const settings = parseAppSettings(officialExport.settings);

function txn(partial: Partial<Transaction> & Pick<Transaction, "id" | "amount">): Transaction {
  return {
    date: "2026-05-13",
    account_id: "acct-credit",
    payee_name: "Candlenut",
    category_name: "Dining Out",
    memo: "Birthday supper",
    approved: true,
    ...partial,
  };
}

test("builds per-card miles and groups flagged dining separately from unflagged spend", () => {
  const report = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: "2026-03-01",
    to: "2026-05-31",
    groupBy: "flag",
    accountIds: [],
    transactions: [
      txn({ id: "dining", amount: -86600, flag_color: "red", flag_name: "Dining" }),
      txn({ id: "online", amount: -228900, date: "2026-05-04", payee_name: "MUJI", category_name: "Shopping", memo: "Home bits", flag_color: "blue", flag_name: "Online" }),
      txn({ id: "flight", amount: -488900, date: "2026-04-12", payee_name: "Scoot", category_name: "Holiday", memo: "Taipei flights" }),
    ],
  });

  expect(report.cards).toHaveLength(1);
  expect(report.cards[0]!.card.name).toBe("Travel Card");
  expect(report.totals.spend).toBeGreaterThan(0);
  expect(report.groups.map((row) => row.label).sort()).toEqual(["Dining", "Online", "Unflagged"].sort());

  const byPayee = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: "2026-03-01",
    to: "2026-05-31",
    groupBy: "payee",
    accountIds: [],
    transactions: [
      txn({ id: "dining", amount: -86600, flag_color: "red", flag_name: "Dining" }),
      txn({ id: "online", amount: -228900, date: "2026-05-04", payee_name: "MUJI", category_name: "Shopping", memo: "Home bits", flag_color: "blue", flag_name: "Online" }),
    ],
  });
  expect(byPayee.groups.map((row) => row.label).sort()).toEqual(["Candlenut", "MUJI"]);
});

test("account filter hides cards whose HowMuch account is not selected", () => {
  const report = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: null,
    to: null,
    groupBy: "flag",
    accountIds: ["acct-everyday"],
    transactions: [txn({ id: "dining", amount: -86600, flag_color: "red" })],
  });
  expect(report.cards).toHaveLength(0);
  expect(report.groups).toHaveLength(0);
});
