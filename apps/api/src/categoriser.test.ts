import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";
import { applyMigrations } from "./db";
import { createHandler } from "./http";
import { LedgerRepository } from "./repository";
import { categoryOptions, payeeSearchTerm } from "./categoriser";

const config = { dbPath: ":memory:", port: 0, apiToken: "test-token", defaultPlanId: "test-plan", transitionReadOnly: false };

async function seeded() {
  const db = new Database(":memory:"); applyMigrations(db);
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertPlan("test-plan", { id: "test-plan", name: "Plan" });
  await repo.upsertAccount("test-plan", { id: "card", name: "Visa" });
  await repo.upsertCategoryGroup("test-plan", { id: "living", name: "Living" });
  await repo.upsertCategory("test-plan", { id: "food", name: "Food" }, "living");
  await repo.upsertCategory("test-plan", { id: "transport", name: "Transport" }, "living");
  await repo.upsertCategory("test-plan", { id: "old", name: "Old", hidden: true }, "living");
  await repo.upsertCategoryGroup("test-plan", { id: "cc", name: "Credit Card Payments" });
  await repo.upsertCategory("test-plan", { id: "visa-payment", name: "Visa" }, "cc");
  await repo.upsertPayee("test-plan", { id: "grab", name: "Grab" });
  for (const [id, category] of [["t1", "transport"], ["t2", "transport"], ["t3", "food"]]) {
    await repo.createTransaction("test-plan", { id, account_id: "card", date: "2026-09-01", amount: -12_000, payee_id: "grab", category_id: category });
  }
  return db;
}

function fakeJev(sent: any[]) {
  return async (_url: string, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    sent.push({ headers: new Headers(init?.headers), body });
    const answers = Object.fromEntries(Object.keys(body.questions).map((name) => [name, {
      type: "choice",
      choice: "Living: Transport",
      confidence: 0.8,
      probabilities: { "Living: Transport": 0.85, "Living: Food": 0.1, "None of these": 0.05 },
    }]));
    return new Response(JSON.stringify({ model: "jev-test", answers, usage: { input_tokens: 10, output_tokens: 1 } }), { headers: { "content-type": "application/json" } });
  };
}

const post = (handler: (request: Request) => Promise<Response>, body: unknown, headers: Record<string, string> = { authorization: "Bearer test-token" }) =>
  handler(new Request("https://howmuch.test/api/tools/categorise?plan_id=test-plan", { method: "POST", headers, body: JSON.stringify(body) }));

test("offers visible plan categories and maps Jev's choice back to ids", async () => {
  const db = await seeded();
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: fakeJev(sent) });
  try {
    const response = await post(handler, { transactions: [{ key: "draft", payee_id: "grab", payee_name: "Grab", memo: "ride home", amount: -15_500, account_name: "Visa" }] });
    expect(response.status).toBe(200);
    const { data } = await response.json();
    expect(data.model).toBe("jev-test");
    expect(data.suggestions).toEqual([{
      key: "draft",
      suggestion: { category_id: "transport", category_name: "Transport", group_name: "Living", probability: 0.85 },
      confidence: 0.8,
      alternatives: [{ category_id: "food", category_name: "Food", group_name: "Living", probability: 0.1 }],
    }]);

    expect(sent).toHaveLength(1);
    expect(sent[0].headers.get("authorization")).toBe("Bearer ts-key");
    const question = sent[0].body.questions.t0;
    expect(question.type).toBe("choice");
    expect(Object.keys(question.criteria)).toEqual(["Living: Food", "Living: Transport", "None of these"]);
    expect(sent[0].body.state.transactions[0]).toMatchObject({
      payee: "Grab", memo: "ride home", amount: "15.50", account: "Visa",
      payee_history: [{ category: "Living: Transport", times: 2 }, { category: "Living: Food", times: 1 }],
    });
  } finally { db.close(); }
});

test("reports a missing key and validates input without calling Jev", async () => {
  const db = await seeded();
  const sent: any[] = [];
  try {
    const off = createHandler({ db, config, typesafeFetch: fakeJev(sent) });
    const missing = await post(off, { transactions: [{ payee_name: "Grab", amount: -1000 }] });
    expect(missing.status).toBe(503);
    expect((await missing.json()).error.name).toBe("categoriser_not_configured");

    const on = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: fakeJev(sent) });
    expect((await post(on, { transactions: [] })).status).toBe(400);
    expect((await post(on, { transactions: [{ amount: -1000 }] })).status).toBe(400);
    expect((await post(on, { transactions: Array.from({ length: 26 }, () => ({ payee_name: "x", amount: -1 })) })).status).toBe(400);
    expect((await post(on, { transactions: [{ payee_name: "Grab", amount: -1 }] }, {})).status).toBe(401);
    expect(sent).toHaveLength(0);
  } finally { db.close(); }
});

test("surfaces a rejected TypeSafe key as a gateway error", async () => {
  const db = await seeded();
  const handler = createHandler({
    db,
    config: { ...config, typesafeApiKey: "bad" },
    typesafeFetch: async () => new Response(JSON.stringify({ error: "unauthorised" }), { status: 401 }),
  });
  try {
    const response = await post(handler, { transactions: [{ payee_name: "Grab", amount: -1000 }] });
    expect(response.status).toBe(502);
    expect((await response.json()).error.detail).toContain("API key");
  } finally { db.close(); }
});

test("keeps inflow categories from hidden groups but drops hidden spending categories", () => {
  const options = categoryOptions([
    { id: "internal", name: "Internal Master Category", hidden: true, categories: [
      { id: "rta", name: "Inflow: Ready to Assign" },
      { id: "uncat", name: "Uncategorized" },
    ] },
    { id: "g", name: "Bills", categories: [{ id: "rent", name: "Rent" }, { id: "gone", name: "Gone", deleted: true }] },
  ]);
  expect(options.map((option) => option.category_id)).toEqual(["rta", "rent"]);
});

test("finds past transactions under other spellings of the payee", async () => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertPayee("test-plan", { id: "grabfood", name: "GRABFOOD*ORDER 8812" });
  await repo.createTransaction("test-plan", { id: "t4", account_id: "card", date: "2026-09-05", amount: -25_000, payee_id: "grabfood", memo: "dinner", category_id: "food" });
  await repo.createTransaction("test-plan", { id: "t5", account_id: "card", date: "2026-09-06", amount: -9_000, payee_id: "grabfood", memo: "dinner", category_id: "food" });
  await repo.createTransaction("test-plan", { id: "pending", account_id: "card", date: "2026-09-07", amount: -4_000, payee_id: "grabfood" });
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: fakeJev(sent) });
  try {
    const response = await post(handler, { transactions: [{ key: "pending", payee_name: "GRAB*RIDES SG 1234", amount: -4_000 }] });
    expect(response.status).toBe(200);
    const similar = sent[0].body.state.transactions[0].similar_past_transactions;
    // Newest first, one row per distinct payee/memo/category, without the row being classified.
    expect(similar.map((row: any) => [row.payee, row.memo, row.category])).toEqual([
      ["GRABFOOD*ORDER 8812", "dinner", "Living: Food"],
      ["Grab", null, "Living: Food"],
      ["Grab", null, "Living: Transport"],
    ]);
    expect(sent[0].body.state.transactions[0].payee_history).toEqual([]);
  } finally { db.close(); }
});

test("picks a distinctive payee word to search by", () => {
  expect(payeeSearchTerm("GRAB*RIDES SG 1234")).toBe("grab");
  expect(payeeSearchTerm("The Coffee Bean Pte Ltd")).toBe("coffee");
  expect(payeeSearchTerm("SP Group")).toBeNull();
  expect(payeeSearchTerm(null)).toBeNull();
});
