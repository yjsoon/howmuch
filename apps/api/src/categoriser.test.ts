import { Database } from "bun:sqlite";
import { expect, spyOn, test } from "bun:test";
import { applyMigrations } from "./db";
import { createHandler } from "./http";
import { LedgerRepository } from "./repository";
import { categoryOptions, suggestCategories } from "./categoriser";
import { reviewRows, suggestionRequestItems } from "../../web/src/lib/category-suggestions";
import { api } from "../../web/src/api/client";

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
      evidence: { same_payee: 3, similar_names: 3 },
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
    const sentItem = sent[0].body.state.transactions[0];
    expect(sentItem.payee_cleaned).toBe("grab rides");
    // Grouped by cleaned name and category with counts, without the row being classified.
    // GrabFood is a related but different merchant ("grab" only prefixes "grabfood"), so it is left out.
    expect(sentItem.similar_past_transactions.map((row: any) => [row.payee, row.category, row.times, row.name_similarity])).toEqual([
      ["Grab", "Living: Transport", 2, 0.83],
      ["Grab", "Living: Food", 1, 0.83],
    ]);
    expect(sent[0].body.state.transactions[0].payee_history).toEqual([]);
  } finally { db.close(); }
});


function scriptedJev(sent: any[], confidence: number, choice = "Living: Transport") {
  return async (_url: string, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    sent.push(body);
    const answers = Object.fromEntries(Object.keys(body.questions).map((name) => [name, {
      type: "choice", choice, confidence, probabilities: { [choice]: confidence },
    }]));
    return Response.json({ model: "jev-test", answers, usage: { input_tokens: 1, output_tokens: 1 } });
  };
}

const createOne = (handler: (request: Request) => Promise<Response>, transaction: Record<string, unknown>) =>
  handler(new Request("https://howmuch.test/v1/plans/test-plan/transactions", {
    method: "POST",
    headers: { authorization: "Bearer test-token", "content-type": "application/json" },
    body: JSON.stringify({ transaction: { account_id: "card", date: "2026-09-25", amount: -8_000, ...transaction } }),
  }));

test("a create that names only a payee is categorised on the server when Jev is confident", async () => {
  const db = await seeded();
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev(sent, 0.9) });
  try {
    const response = await createOne(handler, { payee_name: "grab", memo: "ride" });
    expect(response.status).toBe(201);
    expect((await response.json()).data.transaction).toMatchObject({ payee_name: "Grab", category_id: "transport", category_name: "Transport" });
    // The name resolved to the known payee, so its history went along.
    expect(sent[0].state.transactions[0].payee_history).toEqual([{ category: "Living: Transport", times: 2 }, { category: "Living: Food", times: 1 }]);

    const quick = await handler(new Request("https://howmuch.test/api/mobile/quick-entry", {
      method: "POST",
      headers: { authorization: "Bearer test-token", "content-type": "application/json" },
      body: JSON.stringify({ account_id: "card", amount: "-4.50", payee_name: "New Cafe" }),
    }));
    expect(quick.status).toBe(201);
    expect((await quick.json()).data.transaction.category_id).toBe("transport");

    const batch = await handler(new Request("https://howmuch.test/v1/plans/test-plan/transactions", {
      method: "POST",
      headers: { authorization: "Bearer test-token", "content-type": "application/json" },
      body: JSON.stringify({ transactions: [
        { id: "b1", account_id: "card", date: "2026-09-25", amount: -1_000, payee_name: "Grab" },
        { id: "b2", account_id: "card", date: "2026-09-25", amount: -1_000, payee_name: "Grab", category_id: "food" },
      ] }),
    }));
    expect(batch.status).toBe(201);
    const repo = new LedgerRepository(db, "test-plan");
    expect((await repo.getTransaction("test-plan", "b1")).category_id).toBe("transport");
    expect((await repo.getTransaction("test-plan", "b2")).category_id).toBe("food");
    // One question for b1 only: an explicit category is never second-guessed.
    expect(Object.keys(sent.at(-1).questions)).toEqual(["t0"]);
  } finally { db.close(); }
});

test("creates stay uncategorised when Jev is unsure, failing or not configured", async () => {
  const db = await seeded();
  try {
    const unsure = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev([], 0.3) });
    const low = await createOne(unsure, { payee_name: "Grab" });
    expect(low.status).toBe(201);
    expect((await low.json()).data.transaction.category_id).toBeNull();

    const none = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev([], 0.95, "None of these") });
    expect((await (await createOne(none, { payee_name: "Grab" })).json()).data.transaction.category_id).toBeNull();

    const down = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: async () => new Response("busy", { status: 503 }) });
    const failed = await createOne(down, { payee_name: "Grab" });
    expect(failed.status).toBe(201);
    expect((await failed.json()).data.transaction.category_id).toBeNull();

    const sent: any[] = [];
    const off = createHandler({ db, config, typesafeFetch: scriptedJev(sent, 0.9) });
    expect((await (await createOne(off, { payee_name: "Grab" })).json()).data.transaction.category_id).toBeNull();
    expect(sent).toHaveLength(0);
  } finally { db.close(); }
});

test("transfers are skipped and a retried create keeps the category from its first attempt", async () => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertAccount("test-plan", { id: "savings", name: "Savings" });
  const transferPayee = (await repo.listPayees("test-plan")).find((payee: any) => payee.transfer_account_id === "savings");
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev(sent, 0.9) });
  try {
    expect((await createOne(handler, { payee_name: transferPayee.name })).status).toBe(201);
    expect(sent).toHaveLength(0);

    const first = await createOne(handler, { id: "offline-1", payee_name: "Grab" });
    expect((await first.json()).data.transaction.category_id).toBe("transport");
    const retry = await createOne(handler, { id: "offline-1", payee_name: "Grab" });
    expect(retry.status).toBe(201);
    expect((await retry.json()).data.transaction.category_id).toBe("transport");
    expect(sent).toHaveLength(1);
  } finally { db.close(); }
});

test("coded names of one merchant count as evidence; an unrecognisable name needs a surer answer", async () => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  for (const [id, code] of [["c1", "A-5X7K9"], ["c2", "B-8Q2M1"], ["c3", "C-1Z9P4"]]) {
    await repo.upsertPayee("test-plan", { id: `payee-${id}`, name: `GRAB*${code} SINGAPORE SG` });
    await repo.createTransaction("test-plan", { id, account_id: "card", date: "2026-09-10", amount: -9_000, payee_id: `payee-${id}`, category_id: "transport" });
  }
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev(sent, 0.7) });
  try {
    const coded = await (await createOne(handler, { payee_name: "GRAB*D-7T3W2 SINGAPORE SG" })).json();
    expect(coded.data.transaction.category_id).toBe("transport");
    const examples = sent[0].state.transactions[0].similar_past_transactions;
    // Three differently coded payees, one Food Grab row, collapse to two examples.
    expect(examples.map((row: any) => [row.category, row.times, row.name_similarity])).toEqual([
      ["Living: Transport", 5, 1],
      ["Living: Food", 1, 1],
    ]);

    const unknown = await (await createOne(handler, { payee_name: "QXZ*8812 MERCHANT 00" })).json();
    expect(unknown.data.transaction.category_id).toBeNull();
    expect(sent[1].state.transactions[0].similar_past_transactions).toEqual([]);
  } finally { db.close(); }
});

test.each([1, 2])("a review of %i target rows cannot use those targets as independent history", async (count) => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertPayee("test-plan", { id: "only", name: "Only Merchant" });
  const rows = await Promise.all(Array.from({ length: count }, (_, index) => repo.createTransaction("test-plan", {
    id: `target-${index}`, account_id: "card", date: "2026-09-25", amount: -2_000, payee_id: "only", category_id: "food",
  })));
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev(sent, 0.7) });
  const body = { transactions: rows.map((row) => ({ key: row.id, payee_id: row.payee_id, payee_name: row.payee_name, amount: row.amount })) };
  try {
    const response = await post(handler, body);
    expect(response.status).toBe(200);
    const { data } = await response.json();
    expect(sent[0].state.transactions.map((item: any) => item.payee_history)).toEqual(rows.map(() => []));
    expect(data.suggestions.map((item: any) => item.evidence)).toEqual(rows.map(() => ({ same_payee: 0, similar_names: 0 })));
    expect(reviewRows(rows, data.suggestions).map((row) => row.include)).toEqual(rows.map(() => false));

    // A different transaction for the very same payee is genuine evidence.
    await repo.createTransaction("test-plan", { id: "independent", account_id: "card", date: "2026-09-01", amount: -3_000, payee_id: "only", category_id: "transport" });
    const next = await (await post(handler, body)).json();
    expect(sent[1].state.transactions[0].payee_history).toEqual([{ category: "Living: Transport", times: 1 }]);
    expect(next.data.suggestions[0].evidence).toEqual({ same_payee: 1, similar_names: 1 });
    expect(reviewRows(rows, next.data.suggestions).every((row) => row.include)).toBe(true);
  } finally { db.close(); }
});

test.each([
  ["7-11", "7 ELEVEN-TAMPINES CENTR"],
  ["7 ELEVEN-TAMPINES CENTR", "7-11"],
  ["4FINGERS CRISPY CHICKE", "4FINGERS"],
  ["4FINGERS", "4FINGERS CRISPY CHICKE"],
  ["Café Nero", "Cafe Nero"],
  ["Cafe Nero", "Café Nero"],
])("retrieves old normalised merchant history: %s → %s", async (historicalName, newName) => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertPayee("test-plan", { id: "merchant", name: historicalName });
  await repo.createTransaction("test-plan", { id: "history", account_id: "card", date: "2020-01-01", amount: -2_000, payee_id: "merchant", category_id: "food" });
  // A recent-plan fallback alone cannot find the older known merchant.
  for (let index = 0; index < 151; index++) {
    await repo.createTransaction("test-plan", { id: `noise-${index}`, account_id: "card", date: "2026-09-24", amount: -1_000, payee_id: "grab", category_id: "transport" });
  }
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: scriptedJev(sent, 0.7, "Living: Food") });
  try {
    const response = await createOne(handler, { payee_name: newName });
    expect(response.status).toBe(201);
    expect((await response.json()).data.transaction.category_id).toBe("food");
    expect(sent[0].state.transactions[0].payee_history).toEqual([]);
    expect(sent[0].state.transactions[0].similar_past_transactions).toMatchObject([{ payee: historicalName, category: "Living: Food", times: 1 }]);
    const unrelated = await createOne(handler, { payee_name: "Unrelated Bookshop" });
    expect((await unrelated.json()).data.transaction.category_id).toBeNull();
  } finally { db.close(); }
});

test("normalised payee retrieval is bounded and shared by all targets in a batch", async () => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  for (let index = 0; index < 10; index++) {
    await repo.upsertPayee("test-plan", { id: `merchant-${index}`, name: `7-11 ${1000 + index}` });
    await repo.createTransaction("test-plan", { id: `history-${index}`, account_id: "card", date: "2020-01-01", amount: -2_000, payee_id: `merchant-${index}`, category_id: "food" });
  }
  const reads = spyOn(repo, "listTransactionsPage");
  const payees = spyOn(repo, "listPayees");
  try {
    const result = await suggestCategories(repo, "test-plan", ["draft-a", "draft-b"].map((key) => ({
      key, payee_id: null, payee_name: "7-11", memo: null, amount: -1_000, date: null, account_name: null,
    })), { apiKey: "test", fetch: scriptedJev([], 0.7, "Living: Food") });
    expect(payees).toHaveBeenCalledTimes(1);
    expect(reads.mock.calls.map(([, filters]) => filters)).toEqual([
      { q: "seve", limit: 150 },
      ...Array.from({ length: 8 }, (_, index) => ({ payeeId: `merchant-${index}`, limit: 50 })),
    ]);
    expect(result.suggestions.map((item) => item.evidence)).toEqual([
      { same_payee: 0, similar_names: 8 }, { same_payee: 0, similar_names: 8 },
    ]);
  } finally { reads.mockRestore(); payees.mockRestore(); db.close(); }
});

test.each([26, 100])("all %i web review targets are excluded across request batches", async (count) => {
  const db = await seeded();
  const repo = new LedgerRepository(db, "test-plan");
  await repo.upsertPayee("test-plan", { id: "review-payee", name: "Review Merchant" });
  const rows = [];
  for (let index = 0; index < count; index++) {
    rows.push(await repo.createTransaction("test-plan", { id: `review-${index}`, account_id: "card", date: "2026-09-25", amount: -1_000, payee_id: "review-payee", category_id: "food" }));
  }
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    sent.push(body);
    return Response.json({ model: "jev-test", usage: { input_tokens: 1, output_tokens: 1 }, answers: Object.fromEntries(
      Object.keys(body.questions).map((key) => [key, { type: "choice", choice: "Living: Transport", confidence: 0.7,
        probabilities: { "Living: Transport": 0.7, "Living: Food": 0.25, "None of these": 0.05 } }]),
    ) });
  } });
  const originalFetch = globalThis.fetch;
  const requests: any[] = [];
  globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    const headers = new Headers(init?.headers);
    headers.set("authorization", "Bearer test-token");
    return handler(new Request(new URL(String(path), "https://howmuch.test"), { ...init, headers }));
  }) as typeof fetch;
  try {
    const suggestions = await api.suggestCategories("test-plan", suggestionRequestItems(rows));
    expect(suggestions.every((item) => item.evidence.same_payee === 0 && item.evidence.similar_names === 0)).toBe(true);
    expect(reviewRows(rows, suggestions).every((row) => !row.include)).toBe(true);
    expect(requests.map((request) => request.transactions.length)).toEqual(count === 26 ? [25, 1] : [25, 25, 25, 25]);
    expect(requests.every((request) => JSON.stringify(request.exclude_transaction_ids) === JSON.stringify(rows.map((row) => row.id)))).toBe(true);
    expect(sent.flatMap((body) => body.state.transactions).every((item: any) => item.payee_history.length === 0 && item.similar_past_transactions.length === 0)).toBe(true);

    await repo.createTransaction("test-plan", { id: "outside-review", account_id: "card", date: "2026-09-26", amount: -2_000, payee_id: "review-payee", category_id: "transport" });
    const next = await api.suggestCategories("test-plan", suggestionRequestItems(rows));
    expect(next.every((item) => item.evidence.same_payee === 1 && item.evidence.similar_names === 1)).toBe(true);
    expect(reviewRows(rows, next).every((row) => row.include)).toBe(true);
    for (const row of rows) expect((await repo.getTransaction("test-plan", row.id)).category_id).toBe("food");
  } finally { globalThis.fetch = originalFetch; db.close(); }
});

test("review exclusions are bounded, validated, and cannot replace local target exclusions", async () => {
  const db = await seeded();
  const sent: any[] = [];
  const handler = createHandler({ db, config: { ...config, typesafeApiKey: "ts-key" }, typesafeFetch: fakeJev(sent) });
  const transactions = [{ key: "t1", payee_id: "grab", payee_name: "Grab", amount: -1_000 }];
  try {
    for (const exclude_transaction_ids of [null, "t1", {}, [1], [null], [""], [" "], Array(101).fill("t1")]) {
      expect((await post(handler, { transactions, exclude_transaction_ids })).status).toBe(400);
    }
    expect(sent).toHaveLength(0);
    for (const exclude_transaction_ids of [[], ["t2"], Array.from({ length: 100 }, (_, i) => `unknown-${i}`)]) {
      const response = await post(handler, { transactions, exclude_transaction_ids });
      expect(response.status).toBe(200);
      const { data } = await response.json();
      expect(data.suggestions[0].evidence).toEqual({ same_payee: exclude_transaction_ids[0] === "t2" ? 1 : 2, similar_names: exclude_transaction_ids[0] === "t2" ? 1 : 2 });
    }
  } finally { db.close(); }
});
