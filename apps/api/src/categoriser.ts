import {
  APIConnectionError,
  APIError,
  AuthenticationError,
  choice,
  PermissionDeniedError,
  RateLimitError,
  TypeSafeClient,
  type ChoiceQuestion,
  type Fetch,
} from "@typesafe-ai/sdk";
import type { LedgerStore } from "./storage";
import { NotFoundError, ValidationError } from "./repository";
import type { TransactionInput } from "./types";

/**
 * Category suggestions from TypeSafe's Jev model.
 *
 * Jev answers a Choice question whose options are the plan's own categories,
 * so the model can only ever pick a label this code offered: payee and memo
 * text cannot steer it into anything else. Code owns everything around that
 * judgment: which categories are offered, the payee's history, mapping the
 * label back to an id, and the decision to apply it, which stays with the user.
 */

export const MAX_CATEGORISE_BATCH = 25;
const PAYEE_HISTORY_LIMIT = 50;
const PAYEE_HISTORY_CATEGORIES = 5;
const SIMILAR_SEARCH_LIMIT = 60;
const SIMILAR_EXAMPLES = 8;
/** Words that say nothing about what a merchant sells, so they make poor search terms. */
const GENERIC_PAYEE_WORDS = new Set([
  "the", "and", "pte", "ltd", "limited", "inc", "llc", "company", "group", "holdings", "singapore", "sgp",
  "www", "com", "http", "https", "payment", "payments", "pay", "paynow", "card", "visa", "mastercard",
  "purchase", "pos", "nets", "transfer", "online", "debit", "credit", "ref",
]);
const ALTERNATIVES = 3;
const NO_MATCH = "None of these";

export type CategoriserConfig = {
  apiKey?: string;
  model?: string;
  fetch?: Fetch;
};

/** Per-attempt timeout and retries; creates use a tighter budget than the review panel. */
type CallBudget = { timeout: number; maxRetries: number };
const REVIEW_BUDGET: CallBudget = { timeout: 20_000, maxRetries: 1 };
const CREATE_BUDGET: CallBudget = { timeout: 5_000, maxRetries: 0 };

/**
 * Minimum confidence for a create to take Jev's category without review.
 * A starting point to tune against corrections, not a validated threshold.
 */
export const AUTO_CATEGORISE_MIN_CONFIDENCE = 0.6;

export type CategoriseItem = {
  key: string;
  payee_id: string | null;
  payee_name: string | null;
  memo: string | null;
  amount: number;
  date: string | null;
  account_name: string | null;
};

export type CategoryOption = { category_id: string; category_name: string; group_name: string };

export type CategorySuggestion = {
  key: string;
  /** Null when Jev chose "none of these". */
  suggestion: (CategoryOption & { probability: number }) | null;
  /** Concentration of Jev's distribution, from zero to one. Not a correctness guarantee. */
  confidence: number;
  alternatives: Array<CategoryOption & { probability: number }>;
};

export type CategoriseResult = {
  model: string;
  suggestions: CategorySuggestion[];
  usage: { input_tokens: number; output_tokens: number };
};

export class CategoriserUnavailableError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

export function parseCategoriseItems(body: any): CategoriseItem[] {
  const raw = body?.transactions;
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new ValidationError("transactions must be a non-empty array");
  }
  if (raw.length > MAX_CATEGORISE_BATCH) {
    throw new ValidationError(`At most ${MAX_CATEGORISE_BATCH} transactions can be categorised per request`);
  }
  const keys = new Set<string>();
  return raw.map((item: any, index: number) => {
    const key = typeof item?.key === "string" && item.key ? item.key : String(index);
    if (keys.has(key)) throw new ValidationError(`Duplicate transaction key: ${key}`);
    keys.add(key);
    const amount = Number(item?.amount);
    if (!Number.isInteger(amount)) throw new ValidationError(`transactions[${index}].amount must be integer milliunits`);
    const payeeName = text(item?.payee_name, 200);
    const memo = text(item?.memo, 500);
    if (!payeeName && !memo) throw new ValidationError(`transactions[${index}] needs a payee_name or memo`);
    return {
      key,
      payee_id: text(item?.payee_id, 100),
      payee_name: payeeName,
      memo,
      amount,
      date: typeof item?.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(item.date) ? item.date : null,
      account_name: text(item?.account_name, 200),
    };
  });
}

/**
 * Categories Jev may choose from: live, visible budget categories, plus inflow
 * categories so income can be recognised. Credit card payment categories are
 * left out because HowMuch assigns them from transfers, never by judgment.
 */
export function categoryOptions(groups: any[]): CategoryOption[] {
  const options: CategoryOption[] = [];
  for (const group of groups) {
    if (group.deleted || /credit card payments/i.test(group.name)) continue;
    for (const category of group.categories ?? []) {
      if (category.deleted || /^(uncategori[sz]ed|split\b)/i.test(category.name)) continue;
      const inflow = /inflow|ready to assign/i.test(category.name);
      if ((group.hidden || category.hidden) && !inflow) continue;
      options.push({ category_id: category.id, category_name: category.name, group_name: group.name });
    }
  }
  return options;
}

export async function suggestCategories(
  repo: LedgerStore,
  planId: string,
  items: CategoriseItem[],
  config: CategoriserConfig,
  budget: CallBudget = REVIEW_BUDGET,
): Promise<CategoriseResult> {
  if (!config.apiKey) {
    throw new CategoriserUnavailableError(503, "categoriser_not_configured", "Category suggestions are not configured on this server");
  }
  const options = categoryOptions(await repo.listCategoryGroups(planId));
  if (options.length === 0) {
    throw new ValidationError("This plan has no categories to suggest from");
  }

  // Labels are what Jev reads, so they carry the group for context. Ids stay in code.
  const byLabel = new Map<string, CategoryOption>();
  const labelFor = new Map<string, string>();
  for (const option of options) {
    let label = `${option.group_name}: ${option.category_name}`;
    for (let n = 2; byLabel.has(label) || label === NO_MATCH; n++) label = `${option.group_name}: ${option.category_name} (${n})`;
    byLabel.set(label, option);
    labelFor.set(option.category_id, label);
  }
  const criteria: Record<string, string | null> = Object.fromEntries([...byLabel.keys()].map((label) => [label, null]));
  criteria[NO_MATCH] = "No listed category fits this transaction, or it needs a person to decide (for example a refund or reimbursement of unclear purpose).";

  const [histories, similar] = await Promise.all([
    payeeHistories(repo, planId, items, labelFor),
    similarTransactions(repo, planId, items, labelFor),
  ]);
  const state = {
    transactions: items.map((item) => ({
      payee: item.payee_name,
      memo: item.memo,
      direction: item.amount < 0 ? "outflow (money spent)" : "inflow (money received)",
      amount: (Math.abs(item.amount) / 1000).toFixed(2),
      date: item.date,
      account: item.account_name,
      payee_history: item.payee_id ? histories.get(item.payee_id) ?? [] : [],
      similar_past_transactions: similar.get(item.key) ?? [],
    })),
  };
  const questions: Record<string, ChoiceQuestion<typeof criteria>> = {};
  items.forEach((_, index) => {
    const path = `transactions[${index}]`;
    questions[`t${index}`] = choice(
      `Which budget category does the transaction \`${path}\` belong to? Use its payee, memo, direction, amount and account. `
        + `\`${path}.payee_history\` counts the categories this exact payee was given before; treat it as strong evidence, `
        + `but not binding when the memo or amount points elsewhere. \`${path}.similar_past_transactions\` are earlier `
        + `transactions whose payee or memo shares a word with this payee, with the category each was given. Some may be `
        + `unrelated merchants that happen to share the word: follow the ones that are clearly the same merchant or the same `
        + `kind of purchase. Inflows are usually income unless they look like a refund.`,
      criteria,
    );
  });

  const client = new TypeSafeClient({
    apiKey: config.apiKey,
    defaultModel: config.model,
    fetch: config.fetch,
    timeout: budget.timeout,
    retry: { maxRetries: budget.maxRetries },
    logLevel: "error",
  });
  let response;
  try {
    response = await client.systemOne({ state, questions });
  } catch (error) {
    throw unavailable(error);
  }

  const suggestions = items.map((item, index): CategorySuggestion => {
    const answer = response.answers[`t${index}`];
    const ranked = Object.entries(answer.probabilities as Record<string, number>)
      .filter(([label]) => byLabel.has(label))
      .sort((a, b) => b[1] - a[1])
      .map(([label, probability]) => ({ ...byLabel.get(label)!, probability }));
    const chosen = byLabel.get(answer.choice);
    return {
      key: item.key,
      suggestion: chosen ? { ...chosen, probability: answer.probabilities[answer.choice] ?? 0 } : null,
      confidence: answer.confidence,
      alternatives: ranked.filter((option) => option.category_id !== chosen?.category_id).slice(0, ALTERNATIVES),
    };
  });
  return { model: response.model, suggestions, usage: response.usage };
}

/**
 * Fills `category_id` on new transactions that name a payee but no category,
 * when Jev is confident. Mutates and returns the inputs.
 *
 * Best effort by design: without a key, or if TypeSafe is slow or failing, the
 * transactions are created uncategorised exactly as before. A create never
 * fails because of this step. Transfers, splits and rows with a category are
 * left alone.
 *
 * Creates are upserts by id, so a retried create (an offline queue resending
 * after a lost response) would otherwise overwrite the category chosen on the
 * first attempt with null. Such a retry keeps the stored category instead, and
 * Jev is not asked again.
 */
export async function autoCategorise<T extends TransactionInput>(
  repo: LedgerStore,
  planId: string,
  inputs: T[],
  config: CategoriserConfig,
): Promise<T[]> {
  if (!config.apiKey) return inputs;
  const uncategorised = inputs.filter((input) => !input.category_id
    && !input.transfer_account_id
    && !input.subtransactions?.length
    && Boolean(input.payee_name?.trim() || input.payee_id));
  if (uncategorised.length === 0) return inputs;

  const candidates: T[] = [];
  for (const input of uncategorised) {
    const existing = input.id ? await existingTransaction(repo, planId, input.id) : null;
    if (existing) {
      if (existing.category_id) input.category_id = existing.category_id;
    } else {
      candidates.push(input);
    }
  }
  if (candidates.length === 0) return inputs;

  const payees = await repo.listPayees(planId);
  const byId = new Map(payees.map((payee: any) => [payee.id, payee]));
  const byName = new Map(payees.map((payee: any) => [String(payee.name).trim().toLowerCase(), payee]));
  const accounts = new Map((await repo.listAccounts(planId)).map((account: any) => [account.id, account.name]));
  const items: Array<{ input: T; item: CategoriseItem }> = [];
  for (const input of candidates) {
    const payee = (input.payee_id ? byId.get(input.payee_id) : undefined)
      ?? (input.payee_name ? byName.get(input.payee_name.trim().toLowerCase()) : undefined);
    if (payee?.transfer_account_id) continue;
    const payeeName = input.payee_name?.trim() || payee?.name || null;
    if (!payeeName) continue;
    items.push({
      input,
      item: {
        key: String(items.length),
        payee_id: payee?.id ?? null,
        payee_name: payeeName.slice(0, 200),
        memo: input.memo?.trim().slice(0, 500) || null,
        amount: input.amount,
        date: input.date ?? null,
        account_name: accounts.get(input.account_id) ?? null,
      },
    });
  }

  const chunks: Array<typeof items> = [];
  for (let start = 0; start < items.length; start += MAX_CATEGORISE_BATCH) chunks.push(items.slice(start, start + MAX_CATEGORISE_BATCH));
  let applied = 0;
  await Promise.all(chunks.map(async (chunk) => {
    try {
      const result = await suggestCategories(repo, planId, chunk.map(({ item }) => item), config, CREATE_BUDGET);
      result.suggestions.forEach((suggestion, index) => {
        if (suggestion.suggestion && suggestion.confidence >= AUTO_CATEGORISE_MIN_CONFIDENCE) {
          chunk[index].input.category_id = suggestion.suggestion.category_id;
          applied += 1;
        }
      });
    } catch (error) {
      // Any failure here, including an unexpected one, leaves the rows uncategorised rather than failing the create.
      const reason = error instanceof CategoriserUnavailableError ? error.code : error instanceof Error ? error.name : "unknown";
      console.warn(JSON.stringify({ event: "auto_categorise_skipped", reason, count: chunk.length }));
    }
  }));
  if (items.length > 0) console.log(JSON.stringify({ event: "auto_categorise", asked: items.length, applied }));
  return inputs;
}

async function existingTransaction(repo: LedgerStore, planId: string, id: string): Promise<any | null> {
  try {
    return await repo.getTransaction(planId, id);
  } catch (error) {
    if (error instanceof NotFoundError) return null;
    throw error;
  }
}

/** Recent categories per payee, most frequent first, labelled as Jev will see them. */
async function payeeHistories(
  repo: LedgerStore,
  planId: string,
  items: CategoriseItem[],
  labelFor: Map<string, string>,
): Promise<Map<string, Array<{ category: string; times: number }>>> {
  const payeeIds = [...new Set(items.map((item) => item.payee_id).filter((id): id is string => Boolean(id)))];
  const entries = await Promise.all(payeeIds.map(async (payeeId) => {
    const page = await repo.listTransactionsPage(planId, { payeeId, limit: PAYEE_HISTORY_LIMIT });
    const counts = new Map<string, number>();
    for (const transaction of page.transactions) {
      if (transaction.subtransactions?.length) continue;
      const label = transaction.category_id ? labelFor.get(transaction.category_id) : undefined;
      if (label) counts.set(label, (counts.get(label) ?? 0) + 1);
    }
    const history = [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, PAYEE_HISTORY_CATEGORIES)
      .map(([category, times]) => ({ category, times }));
    return [payeeId, history] as const;
  }));
  return new Map(entries);
}

/**
 * The most distinctive word of a payee name, for finding its past transactions
 * under other spellings ("GRAB*RIDES 8812" and "Grab" share "grab").
 */
export function payeeSearchTerm(name: string | null): string | null {
  if (!name) return null;
  const words = name.toLowerCase().replace(/[^a-z]+/g, " ").split(" ");
  return words.find((word) => word.length >= 3 && !GENERIC_PAYEE_WORDS.has(word)) ?? null;
}

/**
 * Categorised past transactions whose payee or memo contains the item's payee
 * search term, newest first. Code retrieves the candidates; Jev judges which
 * of them are relevant.
 */
async function similarTransactions(
  repo: LedgerStore,
  planId: string,
  items: CategoriseItem[],
  labelFor: Map<string, string>,
): Promise<Map<string, Array<Record<string, string | null>>>> {
  const excluded = new Set(items.map((item) => item.key));
  const terms = [...new Set(items.map((item) => payeeSearchTerm(item.payee_name)).filter((term): term is string => Boolean(term)))];
  const byTerm = new Map(await Promise.all(terms.map(async (term) => {
    const page = await repo.listTransactionsPage(planId, { q: term, limit: SIMILAR_SEARCH_LIMIT });
    const seen = new Set<string>();
    const examples: Array<Record<string, string | null>> = [];
    for (const transaction of page.transactions) {
      if (examples.length >= SIMILAR_EXAMPLES) break;
      const category = transaction.category_id ? labelFor.get(transaction.category_id) : undefined;
      if (!category || excluded.has(transaction.id) || transaction.transfer_account_id || transaction.subtransactions?.length) continue;
      const payee = transaction.payee_name ?? null;
      const memo = transaction.memo ?? null;
      if (!`${payee ?? ""} ${memo ?? ""}`.toLowerCase().includes(term)) continue;
      // Repeats of one purchase teach nothing new; keep the variety.
      const signature = `${payee}|${memo}|${category}`.toLowerCase();
      if (seen.has(signature)) continue;
      seen.add(signature);
      examples.push({
        payee,
        memo,
        direction: transaction.amount < 0 ? "outflow" : "inflow",
        amount: (Math.abs(transaction.amount) / 1000).toFixed(2),
        date: transaction.date ?? null,
        category,
      });
    }
    return [term, examples] as const;
  })));
  const result = new Map<string, Array<Record<string, string | null>>>();
  for (const item of items) {
    const term = payeeSearchTerm(item.payee_name);
    if (term) result.set(item.key, byTerm.get(term) ?? []);
  }
  return result;
}

function unavailable(error: unknown): CategoriserUnavailableError {
  if (error instanceof AuthenticationError || error instanceof PermissionDeniedError) {
    return new CategoriserUnavailableError(502, "categoriser_unavailable", "Jev rejected the server's TypeSafe API key");
  }
  if (error instanceof RateLimitError) {
    return new CategoriserUnavailableError(429, "categoriser_rate_limited", "Jev is rate limiting requests; try again shortly");
  }
  if (error instanceof APIError || error instanceof APIConnectionError) {
    console.error("TypeSafe request failed", error instanceof APIError ? { status: error.status, requestId: error.requestId } : error.message);
    return new CategoriserUnavailableError(502, "categoriser_unavailable", "Jev could not suggest categories right now");
  }
  throw error;
}

function text(value: unknown, maximum: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, maximum) : null;
}
