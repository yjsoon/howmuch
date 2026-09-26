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
import { nameSimilarity, payeeSearchStem, payeeTokens } from "./payee-names";

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
const SIMILAR_SEARCH_LIMIT = 150;
const SIMILAR_PAYEES = 8;
const SIMILAR_EXAMPLES = 8;
/** Past names scoring below this are a different merchant sharing a word. */
const MIN_NAME_SIMILARITY = 0.6;
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
/**
 * With no history for the payee and no similarly named past transactions, Jev
 * is guessing from the name alone, which goes badly for coded bank names. Such
 * a create needs a much surer answer before it is categorised unreviewed.
 */
export const AUTO_CATEGORISE_MIN_CONFIDENCE_WITHOUT_EVIDENCE = 0.85;

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
  /** Past transactions Jev was shown: the exact payee's, and similarly named ones. */
  evidence: { same_payee: number; similar_names: number };
};

type SimilarExample = {
  payee: string | null;
  memo: string | null;
  direction: string;
  amount: string;
  date: string | null;
  category: string;
  name_similarity: number;
  times: number;
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

/** A web review spans several requests; none of its targets is past evidence. */
export function parseCategoriseExclusions(body: any): string[] {
  const ids = body?.exclude_transaction_ids;
  if (ids === undefined) return [];
  if (!Array.isArray(ids) || ids.length > 100
    || ids.some((id) => typeof id !== "string" || !id.trim())) {
    throw new ValidationError("exclude_transaction_ids must be an array of at most 100 non-blank transaction IDs");
  }
  return ids;
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
  excludeTransactionIds: readonly string[] = [],
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

  const excluded = new Set([...items.map((item) => item.key), ...excludeTransactionIds]);
  const [histories, similar] = await Promise.all([
    payeeHistories(repo, planId, items, labelFor, excluded),
    similarTransactions(repo, planId, items, labelFor, excluded),
  ]);
  const state = {
    transactions: items.map((item) => ({
      payee: item.payee_name,
      payee_cleaned: payeeTokens(item.payee_name).join(" ") || null,
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
        + `Bank payee names often carry reference codes, card numbers, branches and payment words (NETS, PayNow, SQ *, PAYPAL *); `
        + `\`${path}.payee_cleaned\` is the merchant name with those removed, so read the merchant from it. `
        + `\`${path}.payee_history\` counts the categories this exact payee was given before; treat it as strong evidence, `
        + `but not binding when the memo or amount points elsewhere. \`${path}.similar_past_transactions\` are earlier `
        + `transactions with similar merchant names, each with its category, how many such transactions there were, and a `
        + `name_similarity from 0 to 1 (1 means every merchant word matched). A high similarity usually means the same merchant `
        + `under a different code; a lower one may be a different business sharing a word, so weigh it accordingly. `
        + `If the merchant is unrecognisable and there is no history, prefer "${NO_MATCH}" to a guess. `
        + `Inflows are usually income unless they look like a refund.`,
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
    const history = item.payee_id ? histories.get(item.payee_id) ?? [] : [];
    return {
      key: item.key,
      suggestion: chosen ? { ...chosen, probability: answer.probabilities[answer.choice] ?? 0 } : null,
      confidence: answer.confidence,
      alternatives: ranked.filter((option) => option.category_id !== chosen?.category_id).slice(0, ALTERNATIVES),
      evidence: {
        same_payee: history.reduce((sum, entry) => sum + entry.times, 0),
        similar_names: (similar.get(item.key) ?? []).reduce((sum, example) => sum + example.times, 0),
      },
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
        const hasEvidence = suggestion.evidence.same_payee > 0 || suggestion.evidence.similar_names > 0;
        const threshold = hasEvidence ? AUTO_CATEGORISE_MIN_CONFIDENCE : AUTO_CATEGORISE_MIN_CONFIDENCE_WITHOUT_EVIDENCE;
        if (suggestion.suggestion && suggestion.confidence >= threshold) {
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
  excluded: ReadonlySet<string>,
): Promise<Map<string, Array<{ category: string; times: number }>>> {
  const payeeIds = [...new Set(items.map((item) => item.payee_id).filter((id): id is string => Boolean(id)))];
  const entries = await Promise.all(payeeIds.map(async (payeeId) => {
    const page = await repo.listTransactionsPage(planId, { payeeId, limit: PAYEE_HISTORY_LIMIT });
    const counts = new Map<string, number>();
    for (const transaction of page.transactions) {
      if (excluded.has(transaction.id) || transaction.subtransactions?.length) continue;
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
 * Categorised past transactions with similar merchant names, most similar
 * first. Search raw names by stem and known payees by normalised similarity:
 * SQL cannot find "7-11" using its cleaned token "seveneleven". Both sources
 * are bounded, and rows found through both count only once. Rows differing
 * only in reference codes collapse into one example with a count.
 */
async function similarTransactions(
  repo: LedgerStore,
  planId: string,
  items: CategoriseItem[],
  labelFor: Map<string, string>,
  excluded: ReadonlySet<string>,
): Promise<Map<string, SimilarExample[]>> {
  const tokensFor = new Map(items.map((item) => [item.key, payeeTokens(item.payee_name)]));
  const stems = [...new Set([...tokensFor.values()].map(payeeSearchStem).filter((stem): stem is string => Boolean(stem)))];
  const pools = new Map(await Promise.all(stems.map(async (stem) => {
    const page = await repo.listTransactionsPage(planId, { q: stem, limit: SIMILAR_SEARCH_LIMIT });
    return [stem, page.transactions] as const;
  })));
  const payees = (await repo.listPayees(planId))
    .filter((payee: any) => !payee.deleted && !payee.transfer_account_id)
    .map((payee: any) => ({ id: String(payee.id), tokens: payeeTokens(payee.name) }));
  const payeesFor = new Map(items.map((item) => [item.key, payees
    .map((payee) => ({ id: payee.id, similarity: nameSimilarity(tokensFor.get(item.key)!, payee.tokens) }))
    .filter((payee) => payee.similarity >= MIN_NAME_SIMILARITY)
    .sort((a, b) => b.similarity - a.similarity || a.id.localeCompare(b.id))
    .slice(0, SIMILAR_PAYEES)
    .map((payee) => payee.id)]));
  // Fetch each selected payee only once even when a batch names it repeatedly.
  const payeeIds = [...new Set([...payeesFor.values()].flat())];
  const payeePools = new Map(await Promise.all(payeeIds.map(async (payeeId) => {
    const page = await repo.listTransactionsPage(planId, { payeeId, limit: PAYEE_HISTORY_LIMIT });
    return [payeeId, page.transactions] as const;
  })));

  const result = new Map<string, SimilarExample[]>();
  for (const item of items) {
    const tokens = tokensFor.get(item.key)!;
    const stem = payeeSearchStem(tokens);
    if (!stem) continue;
    const grouped = new Map<string, SimilarExample>();
    const candidates = [
      ...(pools.get(stem) ?? []),
      ...(payeesFor.get(item.key) ?? []).flatMap((id) => payeePools.get(id) ?? []),
    ];
    const unique = [...new Map(candidates.map((row) => [row.id, row])).values()]
      .sort((a, b) => b.date.localeCompare(a.date) || b.id.localeCompare(a.id));
    for (const transaction of unique) {
      if (excluded.has(transaction.id) || transaction.transfer_account_id || transaction.subtransactions?.length
        || !transaction.category_id || !labelFor.has(transaction.category_id)) continue;
      const candidateTokens = payeeTokens(transaction.payee_name);
      const similarity = nameSimilarity(tokens, candidateTokens);
      if (similarity < MIN_NAME_SIMILARITY) continue;
      const category = labelFor.get(transaction.category_id)!;
      const key = `${candidateTokens.join(" ")}|${category}`;
      const existing = grouped.get(key);
      if (existing) {
        existing.times += 1;
        continue;
      }
      // Pools are newest first, so the kept example is the most recent of its group.
      grouped.set(key, {
        payee: transaction.payee_name ?? null,
        memo: transaction.memo ?? null,
        direction: transaction.amount < 0 ? "outflow" : "inflow",
        amount: (Math.abs(transaction.amount) / 1000).toFixed(2),
        date: transaction.date ?? null,
        category,
        name_similarity: Math.round(similarity * 100) / 100,
        times: 1,
      });
    }
    const examples = [...grouped.values()]
      .sort((a, b) => b.name_similarity - a.name_similarity || b.times - a.times)
      .slice(0, SIMILAR_EXAMPLES);
    result.set(item.key, examples);
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
