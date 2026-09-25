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
import { ValidationError } from "./repository";

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
const ALTERNATIVES = 3;
const NO_MATCH = "None of these";

export type CategoriserConfig = {
  apiKey?: string;
  model?: string;
  fetch?: Fetch;
};

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

  const histories = await payeeHistories(repo, planId, items, labelFor);
  const state = {
    transactions: items.map((item) => ({
      payee: item.payee_name,
      memo: item.memo,
      direction: item.amount < 0 ? "outflow (money spent)" : "inflow (money received)",
      amount: (Math.abs(item.amount) / 1000).toFixed(2),
      date: item.date,
      account: item.account_name,
      payee_history: item.payee_id ? histories.get(item.payee_id) ?? [] : [],
    })),
  };
  const questions: Record<string, ChoiceQuestion<typeof criteria>> = {};
  items.forEach((_, index) => {
    const path = `transactions[${index}]`;
    questions[`t${index}`] = choice(
      `Which budget category does the transaction \`${path}\` belong to? Use its payee, memo, direction, amount and account. `
        + `\`${path}.payee_history\` lists categories this payee was given before and how many times; treat it as strong evidence, `
        + `but not binding when the memo or amount points elsewhere. Inflows are usually income unless they look like a refund.`,
      criteria,
    );
  });

  const client = new TypeSafeClient({
    apiKey: config.apiKey,
    defaultModel: config.model,
    fetch: config.fetch,
    timeout: 20_000,
    retry: { maxRetries: 1 },
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
