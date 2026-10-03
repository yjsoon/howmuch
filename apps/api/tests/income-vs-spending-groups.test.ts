import { afterEach, describe, expect, test } from "bun:test";
import { BACKENDS, nativeHarness, type NativeHarness } from "./helpers/native-harness";
import { ReportService } from "../src/reports";

const PLAN = "p";
const JUNE = { from: "2026-06-01", to: "2026-06-30" };

const harnesses: NativeHarness[] = [];
afterEach(() => {
  for (const harness of harnesses.splice(0)) harness.close();
});

async function seedJuneLedger(harness: NativeHarness): Promise<void> {
  const { repo } = harness;
  await repo.upsertPayee(PLAN, { id: "to-cash", name: "Transfer : Cash", transfer_account_id: "cash" });
  await repo.upsertPayee(PLAN, { id: "to-savings", name: "Transfer : Savings", transfer_account_id: "savings" });
  await repo.upsertAccount(PLAN, { id: "cash", name: "Cash", transfer_payee_id: "to-cash" });
  // Tracking so a categorised transfer can keep its category (YNAB only
  // categorises transfers off-budget).
  await repo.upsertAccount(PLAN, {
    id: "savings", name: "Loan", type: "otherAsset", on_budget: false, transfer_payee_id: "to-savings",
  });

  await repo.upsertCategoryGroup(PLAN, { id: "everyday", name: "Everyday" });
  await repo.upsertCategoryGroup(PLAN, { id: "hidden", name: "Hidden Categories" });
  await repo.upsertCategoryGroup(PLAN, { id: "inflow", name: "Inflow" });
  await repo.upsertCategory(PLAN, { id: "groceries", category_group_id: "everyday", name: "Groceries" });
  await repo.upsertCategory(PLAN, { id: "dining", category_group_id: "everyday", name: "Dining" });
  await repo.upsertCategory(PLAN, { id: "hidden-fees", category_group_id: "hidden", name: "Hidden fees" });
  await repo.upsertCategory(PLAN, { id: "salary", category_group_id: "inflow", name: "Salary" });

  await repo.upsertPayee(PLAN, { id: "acme", name: "Acme Corp" });
  await repo.upsertPayee(PLAN, { id: "fairprice", name: "FairPrice" });
  await repo.upsertPayee(PLAN, { id: "cafe", name: "Cafe" });
  await repo.upsertPayee(PLAN, { id: "market", name: "Market" });

  await repo.createTransaction(PLAN, {
    id: "salary", account_id: "cash", date: "2026-06-02", amount: 2_000_000,
    payee_id: "acme", category_id: "salary",
  });
  await repo.createTransaction(PLAN, {
    id: "groceries", account_id: "cash", date: "2026-06-05", amount: -300_000,
    payee_id: "fairprice", category_id: "groceries",
  });
  await repo.createTransaction(PLAN, {
    id: "dining-1", account_id: "cash", date: "2026-06-06", amount: -150_000,
    payee_id: "cafe", category_id: "dining",
  });
  await repo.createTransaction(PLAN, {
    id: "dining-2", account_id: "cash", date: "2026-06-07", amount: -50_000,
    payee_id: "cafe", category_id: "dining",
  });
  await repo.createTransaction(PLAN, {
    id: "hidden-fee", account_id: "cash", date: "2026-06-08", amount: -20_000,
    payee_id: "fairprice", category_id: "hidden-fees",
  });
  await repo.createTransaction(PLAN, {
    id: "uncat-spend", account_id: "cash", date: "2026-06-09", amount: -10_000,
  });
  await repo.createTransaction(PLAN, {
    id: "plain-xfer", account_id: "cash", date: "2026-06-10", amount: -100_000,
    payee_id: "to-savings",
  });
  // One-sided categorised transfer (allowed by the API). autoLink is off so D1
  // does not strip the category the way paired on-budget transfers do.
  await repo.createTransaction(PLAN, {
    id: "cat-xfer", account_id: "cash", date: "2026-06-11", amount: -40_000,
    category_id: "groceries", transfer_account_id: "savings", payee_name: "Transfer : Loan",
  }, { autoLink: false });
  await repo.createTransaction(PLAN, {
    id: "refund", account_id: "cash", date: "2026-06-12", amount: 5_000,
    payee_id: "fairprice", category_id: "groceries",
  });
  await repo.createTransaction(PLAN, {
    id: "split", account_id: "cash", date: "2026-06-13", amount: -80_000,
    payee_id: "market",
    subtransactions: [
      { id: "split-groc", amount: -50_000, category_id: "groceries" },
      { id: "split-dine", amount: -30_000, category_id: "dining" },
    ],
  });
  await repo.createTransaction(PLAN, {
    id: "no-payee-in", account_id: "cash", date: "2026-06-14", amount: 100_000,
    category_id: "salary",
  });
  await repo.createTransaction(PLAN, {
    id: "acme-extra", account_id: "cash", date: "2026-06-15", amount: 20_000,
    payee_id: "acme", category_id: "groceries",
  });
}

describe("income vs spending groups", () => {
  for (const backend of BACKENDS) {
    test(`${backend}: groups reconcile to incomeVsSpending and keep quiet / transfer rules`, async () => {
      const harness = await nativeHarness(backend);
      harnesses.push(harness);
      await seedJuneLedger(harness);

      const periods = await harness.request(
        `/api/reports/income-vs-spending?plan_id=${PLAN}&from=${JUNE.from}&to=${JUNE.to}`,
      ).then((response) => response.json());
      const groups = await harness.request(
        `/api/reports/income-vs-spending-groups?plan_id=${PLAN}&from=${JUNE.from}&to=${JUNE.to}`,
      ).then((response) => response.json());

      expect(periods.data.periods).toHaveLength(1);
      expect(periods.data.periods[0].period).toBe("2026-06");
      // Independent expected totals: income 2_125_000, spending 650_000.
      // Plain 100_000 transfer is excluded; categorised 40_000 transfer is in.
      // Quiet-group Hidden fees 20_000 stays in. Split lines count as lines.
      expect(periods.data.periods[0].income).toBe(2_125_000);
      expect(periods.data.periods[0].spending).toBe(650_000);
      expect(groups.data.income).toBe(2_125_000);
      expect(groups.data.spending).toBe(650_000);
      expect(groups.data.net).toBe(1_475_000);

      const spendingNames = groups.data.spending_by_category.map((row: { category_name: string }) => row.category_name);
      expect(spendingNames).toEqual(["Groceries", "Dining", "Hidden fees", "Uncategorised"]);
      expect(groups.data.spending_by_category[0]).toMatchObject({
        category_id: "groceries", amount: 390_000, transaction_count: 3, share: 390_000 / 650_000,
      });
      expect(groups.data.spending_by_category[1]).toMatchObject({
        category_id: "dining", amount: 230_000, transaction_count: 3, share: 230_000 / 650_000,
      });
      expect(groups.data.spending_by_category[2]).toMatchObject({
        category_id: "hidden-fees", amount: 20_000, transaction_count: 1,
      });
      expect(groups.data.spending_by_category[3]).toMatchObject({
        category_id: "uncategorised", amount: 10_000, transaction_count: 1,
      });

      const payees = groups.data.income_by_payee;
      expect(payees.map((row: { payee_name: string }) => row.payee_name)).toEqual(["Acme Corp", "No payee", "FairPrice"]);
      expect(payees[0]).toMatchObject({
        payee_id: "acme",
        amount: 2_020_000,
        transaction_count: 2,
        category_name: "Multiple categories",
        category_id: null,
        category_count: 2,
      });
      expect(payees[1]).toMatchObject({
        payee_id: null,
        payee_name: "No payee",
        amount: 100_000,
        transaction_count: 1,
        category_name: "Salary",
        category_id: "salary",
      });
      expect(payees[2]).toMatchObject({
        payee_id: "fairprice",
        amount: 5_000,
        transaction_count: 1,
        category_name: "Groceries",
      });

      const incomeCategories = groups.data.income_by_category;
      expect(incomeCategories.map((row: { category_name: string }) => row.category_name)).toEqual(["Salary", "Groceries"]);
      expect(incomeCategories[0]).toMatchObject({ category_id: "salary", amount: 2_100_000, transaction_count: 2 });
      expect(incomeCategories[1]).toMatchObject({ category_id: "groceries", amount: 25_000, transaction_count: 2 });
    });

    test(`${backend}: empty months, weeks and years return no period rows, and groups stay zero`, async () => {
      const harness = await nativeHarness(backend);
      harnesses.push(harness);
      await seedJuneLedger(harness);

      const emptyMonth = await harness.request(
        `/api/reports/income-vs-spending?plan_id=${PLAN}&from=2026-07-01&to=2026-07-31&interval=month`,
      ).then((response) => response.json());
      const emptyWeek = await harness.request(
        `/api/reports/income-vs-spending?plan_id=${PLAN}&from=2026-07-06&to=2026-07-12&interval=week`,
      ).then((response) => response.json());
      const emptyYear = await harness.request(
        `/api/reports/income-vs-spending?plan_id=${PLAN}&from=2025-01-01&to=2025-12-31&interval=year`,
      ).then((response) => response.json());
      const emptyGroups = await harness.request(
        `/api/reports/income-vs-spending-groups?plan_id=${PLAN}&from=2026-07-01&to=2026-07-31`,
      ).then((response) => response.json());

      expect(emptyMonth.data.periods).toEqual([]);
      expect(emptyWeek.data.periods).toEqual([]);
      expect(emptyYear.data.periods).toEqual([]);
      expect(emptyGroups.data).toEqual({
        income: 0,
        spending: 0,
        net: 0,
        income_by_payee: [],
        income_by_category: [],
        spending_by_category: [],
      });
    });
  }

  test("SQLite service matches the HTTP envelope for an empty window", async () => {
    const harness = await nativeHarness("SQLite");
    harnesses.push(harness);
    const expected = new ReportService(harness.db).incomeVsSpendingGroups(PLAN, {
      from: "2026-01-01",
      to: "2026-01-31",
    });
    expect(expected).toEqual({
      income: 0,
      spending: 0,
      net: 0,
      income_by_payee: [],
      income_by_category: [],
      spending_by_category: [],
    });
  });
});
