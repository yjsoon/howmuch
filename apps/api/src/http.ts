import type { Database } from "bun:sqlite";
import type { ApiConfig } from "./config";
import { LedgerRepository, NotFoundError, ReconciliationMismatchError, ValidationError } from "./repository";
import { DEFAULT_TRANSACTION_PAGE_SIZE, MAX_TRANSACTION_PAGE_SIZE, type TransactionFilters } from "./types";
import { collectionPostIntent, parseTransactionCreates, parseTransactionUpdates } from "./transaction-batch";
import { ReportService } from "./reports";
import { decimalToMilliunits } from "./money";
import { importCsvRows } from "./importers/csv";
import { importYnabFromApi } from "./importers/ynab";
import type { LedgerStore, ReportStore } from "./storage";
import { SQLiteAuthStore, type AuthStore, type AuthUser } from "./auth-store";
import {
  canonicalUsername,
  newPersonalApiToken,
  newSession,
  passwordCredential,
  safeTokenEqual,
  sha256,
  validPassword,
  verifyPassword,
} from "./password-auth";
import { randomBytes } from "node:crypto";
import { ScheduledTransactionValidationError } from "./scheduled-transactions";

type HandlerOptions = {
  db?: Database;
  repo?: LedgerStore;
  reports?: ReportStore;
  auth?: AuthStore;
  config: ApiConfig;
};

export function createHandler(options: HandlerOptions): (request: Request) => Promise<Response> {
  const { config } = options;
  const repo = options.repo ?? (options.db ? new LedgerRepository(options.db, config.defaultPlanId) : undefined);
  const reports = options.reports ?? (options.db ? new ReportService(options.db) : undefined);
  const auth = options.auth ?? (options.db ? new SQLiteAuthStore(options.db) : undefined);
  if (!repo || !reports || !auth) {
    throw new Error("createHandler requires either db or repo, reports, and auth");
  }

  return async function handle(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url);
      const segments = url.pathname.split("/").filter(Boolean);

      if (url.pathname === "/health") {
        return json({ ok: true });
      }

      if (url.pathname.startsWith("/api/auth/")) {
        return await handleAuth(request, url, auth, config);
      }
      const principal = await authenticate(request, auth, config.apiToken);
      if (!principal) {
        return apiError(401, "not_authorized", "Invalid credentials");
      }
      if (principal.kind === "session"
        && principal.transport === "cookie"
        && isUnsafeMethod(request.method)
        && !sameOrigin(request, url)) {
        return apiError(403, "forbidden", "CSRF validation failed");
      }
      if (config.transitionReadOnly && isTransitionFinancialWrite(request.method, segments)) {
        return apiError(
          423,
          "transition_read_only",
          "Financial changes are temporarily locked while YNAB is the source of truth",
        );
      }

      if (segments[0] === "v1") {
        return await handleV1(request, url, segments, repo, principal, config.defaultPlanId);
      }

      if (segments[0] === "api") {
        return await handleNative(request, url, segments, repo, reports, principal, config.defaultPlanId);
      }

      return apiError(404, "not_found", "Route not found");
    } catch (error) {
      if (error instanceof NotFoundError) {
        return apiError(404, "resource_not_found", error.message, "404.2");
      }
      if (error instanceof ValidationError) {
        return apiError(400, "bad_request", error.message);
      }
      if (error instanceof ScheduledTransactionValidationError) {
        return apiError(400, "bad_request", error.message);
      }
      if (error instanceof ReconciliationMismatchError) {
        return json({
          error: {
            id: "409",
            name: "reconciliation_mismatch",
            detail: error.message,
            current_reconciled_balance: error.currentReconciledBalance,
            projected_reconciled_balance: error.projectedReconciledBalance,
            statement_balance: error.statementBalance,
            difference: error.difference,
          },
        }, 409);
      }
      if (error instanceof Error && error.message === "idempotency-key reuse") {
        return apiError(409, "conflict", error.message);
      }
      if (error instanceof Error && error.message.includes("stale account reconciliation")) {
        return apiError(409, "conflict", "The account changed while it was being reconciled");
      }
      if (error instanceof Error && (error.message === "stale scheduled occurrence" || error.message.includes("stale scheduled transaction"))) {
        return apiError(409, "conflict", "The scheduled transaction changed while its occurrence was being entered");
      }
      console.error("Unhandled API error", error);
      return apiError(500, "internal_server_error", "An internal error occurred");
    }
  };
}

type Principal =
  | { kind: "api-token" }
  | ({ kind: "session"; transport: "cookie" | "bearer" } & AuthUser)
  | ({ kind: "personal-token" } & AuthUser);

async function handleV1(
  request: Request,
  url: URL,
  segments: string[],
  repo: LedgerStore,
  principal: Principal,
  defaultPlanId: string,
): Promise<Response> {
  const method = request.method.toUpperCase();

  if (segments.length === 2 && segments[1] === "user" && method === "GET") {
    const user = principal.kind !== "api-token"
      ? { id: principal.id, username: principal.username }
      : { id: "local-user" };
    return json({ data: { user } });
  }

  const collection = segments[1];
  if (collection !== "plans" && collection !== "budgets") {
    return apiError(404, "not_found", "Route not found");
  }

  const isBudgetAlias = collection === "budgets";
  if (segments.length === 2 && method === "GET") {
    const plans = (await repo.listPlans()).filter((plan: { id: string }) => canRead(principal, plan.id, defaultPlanId));
    return json({ data: isBudgetAlias ? { budgets: plans } : { plans } });
  }

  const planId = segments[2];
  const denied = authorizePlan(principal, planId, defaultPlanId, method);
  if (denied) return denied;
  await repo.ensurePlan(planId);

  if (segments.length === 3 && method === "GET") {
    const plan = await repo.getPlan(planId);
    return json({ data: isBudgetAlias ? { budget: plan } : { plan } });
  }

  const resource = segments[3];

  if (resource === "settings" && segments.length === 4 && method === "GET") {
    return json({ data: { settings: await repo.getSettings(planId) } });
  }

  if (resource === "accounts") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: { accounts: await repo.listAccounts(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      const payload = body.account ?? body;
      if (!payload || (!payload.id && !payload.name)) {
        return apiError(400, "bad_request", "account requires a name");
      }
      const account = await repo.createAccount(planId, payload);
      return json({ data: { account, server_knowledge: await repo.getServerKnowledge(planId) } }, 201);
    }
    const accountId = segments[4];
    if (segments.length === 6 && segments[5] === "reconciliation" && method === "GET") {
      const statementDate = url.searchParams.get("statement_date");
      if (!statementDate) throw new ValidationError("statement_date is required");
      return json({ data: await repo.getAccountReconciliation(planId, accountId, statementDate) });
    }
    if (segments.length === 6 && segments[5] === "reconcile" && method === "POST") {
      const operationId = requireIdempotencyKey(request);
      const body = await readJson(request);
      if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.statement_date !== "string") {
        throw new ValidationError("statement_date is required");
      }
      if (!Number.isSafeInteger(body.statement_balance)) {
        throw new ValidationError("statement_balance must be integer milliunits");
      }
      return json({ data: await repo.reconcileAccount(planId, accountId, body.statement_date, body.statement_balance, { operationId }) });
    }
    if (segments.length === 5 && method === "GET") {
      return json({ data: { account: await repo.getAccount(planId, accountId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { accountId }));
    }
  }

  if (resource === "categories" && segments.length === 4 && method === "GET") {
    return json({ data: { category_groups: await repo.listCategoryGroups(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
  }
  if (resource === "categories") {
    const categoryId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { categoryId }));
    }
  }

  if (resource === "payees") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: { payees: await repo.listPayees(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      const payee = await repo.createPayee(planId, body.payee?.name ?? body.name);
      return json({ data: { payee, server_knowledge: await repo.getServerKnowledge(planId) } }, 201);
    }
    const payeeId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { payeeId }));
    }
  }

  if (resource === "scheduled_transactions") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: { scheduled_transactions: await repo.listScheduledTransactions(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      if (!body.scheduled_transaction || typeof body.scheduled_transaction !== "object" || Array.isArray(body.scheduled_transaction)) {
        throw new ValidationError("scheduled_transaction is required");
      }
      const scheduledTransaction = await repo.createScheduledTransaction(planId, body.scheduled_transaction, scheduledWriteOptions(request));
      return json({ data: { scheduled_transaction: scheduledTransaction, server_knowledge: await repo.getServerKnowledge(planId) } }, 201);
    }
    if (segments.length === 5 && segments[4] === "materialize" && method === "POST") {
      const administrationDenied = authorizePlanAdministration(principal, planId);
      if (administrationDenied) return administrationDenied;
      const requestOperationId = requireIdempotencyKey(request);
      const body = await readJson(request);
      if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.through_date !== "string") {
        throw new ValidationError("through_date is required");
      }
      const result = await repo.materializeScheduledTransactions(planId, body.through_date, body.maximum ?? 5_000, requestOperationId);
      return json({ data: { ...result, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    const scheduledTransactionId = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { scheduled_transaction: await repo.getScheduledTransaction(planId, scheduledTransactionId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && (method === "PATCH" || method === "PUT")) {
      const body = await readJson(request);
      const patch = body.scheduled_transaction ?? body;
      if (!patch || typeof patch !== "object" || Array.isArray(patch)) throw new ValidationError("scheduled_transaction is required");
      const scheduledTransaction = await repo.updateScheduledTransaction(planId, scheduledTransactionId, patch, scheduledWriteOptions(request));
      return json({ data: { scheduled_transaction: scheduledTransaction, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && method === "DELETE") {
      const scheduledTransaction = await repo.deleteScheduledTransaction(planId, scheduledTransactionId, scheduledWriteOptions(request));
      return json({ data: { scheduled_transaction: scheduledTransaction, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "materialize" && method === "POST") {
      const administrationDenied = authorizePlanAdministration(principal, planId);
      if (administrationDenied) return administrationDenied;
      const requestOperationId = requireIdempotencyKey(request);
      const body = await readJson(request);
      if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.occurrence_date !== "string" || typeof body.date !== "string") {
        throw new ValidationError("occurrence_date and date are required");
      }
      const result = await repo.materializeScheduledOccurrence(planId, scheduledTransactionId, body.occurrence_date, body.date, { allowClosedAccount: true, requestOperationId });
      return json({ data: { ...result, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
  }

  if (resource === "scheduled_subtransactions" && segments.length === 4 && method === "GET") {
    return json({ data: { scheduled_subtransactions: await repo.listScheduledSubtransactions(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
  }

  // These source-only YNAB resources have no normalised write model yet. The
  // raw mirror makes them safely available for clients switching over without
  // discarding their existing scheduled/payee-location/movement data.
  const sourceOnlyCollections: Record<string, { type: string; field: string }> = {
    payee_locations: { type: "payee_location", field: "payee_locations" },
    money_movements: { type: "money_movement", field: "money_movements" },
    money_movement_groups: { type: "money_movement_group", field: "money_movement_groups" },
  };
  const sourceOnly = sourceOnlyCollections[resource];
  if (sourceOnly && segments.length === 4 && method === "GET") {
    const sourceObjects = await repo.listYnabRawObjects(planId, sourceOnly.type);
    return json({ data: { [sourceOnly.field]: sourceObjects, server_knowledge: await repo.getServerKnowledge(planId) } });
  }

  if (resource === "months") {
    const month = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { month: await repo.getMonth(planId, month), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 7 && segments[5] === "categories" && method === "PATCH") {
      const body = await readJson(request);
      if (!body || typeof body !== "object" || Array.isArray(body) || !body.category || typeof body.category !== "object" || Array.isArray(body.category)) {
        throw new ValidationError("category with budgeted is required");
      }
      const category = body.category as Record<string, unknown>;
      let updated: any;
      if (Object.hasOwn(category, "target") || Object.hasOwn(category, "restore_target")) {
        if (Object.hasOwn(category, "budgeted")) throw new ValidationError("Update either budgeted or target, not both");
        if (category.restore_target === true) {
          if (Object.hasOwn(category, "target")) throw new ValidationError("restore_target cannot be combined with target");
          updated = await repo.restoreMonthCategoryTarget(planId, month, segments[6]);
        } else if (Object.hasOwn(category, "target")) {
          const target = category.target;
          if (target !== null && (typeof target !== "object" || Array.isArray(target))) throw new ValidationError("target must be an object or null");
          updated = await repo.setMonthCategoryTarget(planId, month, segments[6], target === null
            ? { goal_type: null }
            : target as { goal_type: "TB" | "TBD" | "MF" | "NEED" | "DEBT" | null; goal_target?: number | null; goal_target_month?: string | null });
        } else {
          throw new ValidationError("restore_target must be true");
        }
      } else {
        const budgeted = category.budgeted;
        if (typeof budgeted !== "number" || !Number.isSafeInteger(budgeted)) throw new ValidationError("budgeted must be integer milliunits");
        updated = await repo.setMonthCategoryAssignment(planId, month, segments[6], budgeted);
      }
      return json({ data: { category: updated.categories.find((category: { id: string }) => category.id === segments[6]), month: updated, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { month }));
    }
    if (segments.length === 6 && method === "GET" && (segments[5] === "money_movements" || segments[5] === "money_movement_groups")) {
      const mapping = segments[5] === "money_movements"
        ? { type: "money_movement", field: "money_movements" }
        : { type: "money_movement_group", field: "money_movement_groups" };
      const objects = await repo.listYnabRawObjects(planId, mapping.type);
      const monthStart = month.length === 7 ? `${month}-01` : month;
      return json({ data: { [mapping.field]: objects.filter((object: any) => object.month === monthStart), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
  }

  if (resource === "transactions") {
    if (segments.length === 4 && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url));
    }
    if (segments.length === 4 && method === "PATCH") {
      const result = await repo.updateTransactions(planId, parseTransactionUpdates(await readJson(request)));
      return json({ data: result });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      if (collectionPostIntent(body) === "many") {
        const result = await repo.createTransactions(planId, parseTransactionCreates(body.transactions));
        return json({ data: result }, 201);
      }
      const input = body.transaction;
      if (!input) {
        return apiError(400, "bad_request", "transaction is required");
      }
      const existing = input?.import_id && input?.account_id
        ? await repo.findTransactionByImportId(planId, input.import_id, input.account_id)
        : null;
      if (existing) {
        return json({
          data: {
            transaction: existing,
            transaction_ids: [existing.id],
            duplicate_import_ids: [input.import_id],
            server_knowledge: await repo.getServerKnowledge(planId),
          },
        });
      }
      try {
        const created = await repo.createTransaction(planId, input);
        return json({ data: { transaction: created, transaction_ids: [created.id], server_knowledge: await repo.getServerKnowledge(planId) } }, 201);
      } catch (error) {
        const raced = input?.import_id && input?.account_id
          ? await repo.findTransactionByImportId(planId, input.import_id, input.account_id)
          : null;
        if (raced) {
          return json({
            data: {
              transaction: raced,
              transaction_ids: [raced.id],
              duplicate_import_ids: [input.import_id],
              server_knowledge: await repo.getServerKnowledge(planId),
            },
          });
        }
        throw error;
      }
    }
    if (segments.length === 5 && segments[4] === "import" && method === "POST") {
      const body = await readJson(request);
      const result = await repo.importTransactions(
        planId,
        (body.transactions ?? []).map((transaction: any) => transaction.transaction ?? transaction),
      );
      return json({ data: result }, 201);
    }

    const transactionId = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { transaction: await repo.getTransaction(planId, transactionId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && (method === "PUT" || method === "PATCH")) {
      const body = await readJson(request);
      const updated = await repo.updateTransaction(planId, transactionId, body.transaction ?? body);
      return json({ data: { transaction: updated, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && method === "DELETE") {
      const deleted = await repo.deleteTransaction(planId, transactionId);
      return json({ data: { transaction: deleted, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
  }

  return apiError(404, "not_found", "Route not found");
}

async function handleNative(
  request: Request,
  url: URL,
  segments: string[],
  repo: LedgerStore,
  reports: ReportStore,
  principal: Principal,
  defaultPlanId: string,
): Promise<Response> {
  const method = request.method.toUpperCase();
  const planId = url.searchParams.get("plan_id") ?? defaultPlanId;

  if (segments[1] === "reports" && method === "GET") {
    const denied = authorizePlan(principal, planId, defaultPlanId, method);
    if (denied) return denied;
    await repo.ensurePlan(planId);
    const filters = reportFilters(url);
    if (segments[2] === "spending-breakdown") {
      return json({ data: await reports.spendingBreakdown(planId, filters) });
    }
    if (segments[2] === "income-vs-spending") {
      return json({ data: await reports.incomeVsSpending(planId, filters) });
    }
    if (segments[2] === "net-worth") {
      return json({ data: await reports.netWorth(planId, filters) });
    }
    if (segments[2] === "age-of-money") {
      return json({ data: await reports.ageOfMoney(planId, filters) });
    }
  }

  if (segments[1] === "mobile" && segments[2] === "quick-entry" && method === "POST") {
    const body = await readJson(request);
    const targetPlanId = body.plan_id ?? planId;
    const denied = authorizePlan(principal, targetPlanId, defaultPlanId, method);
    if (denied) return denied;
    await repo.ensurePlan(targetPlanId);
    const amount = body.amount_milli ?? decimalToMilliunits(body.amount);
    const subtransactions = Array.isArray(body.subtransactions)
      ? body.subtransactions.map((sub: any) => ({
          amount: sub.amount_milli ?? decimalToMilliunits(sub.amount),
          payee_id: sub.payee_id ?? null,
          payee_name: sub.payee_name ?? null,
          category_id: sub.category_id ?? null,
          memo: sub.memo ?? null,
        }))
      : undefined;
    const transaction = await repo.createTransaction(targetPlanId, {
      id: body.client_id,
      account_id: body.account_id,
      date: body.date ?? new Date().toISOString().slice(0, 10),
      amount,
      payee_id: body.payee_id ?? null,
      payee_name: body.payee_name ?? body.payee ?? null,
      category_id: body.category_id ?? null,
      memo: body.memo ?? null,
      flag_color: body.flag_color ?? null,
      source_kind: "mobile",
      source_ref: body.client_id ?? null,
      subtransactions,
    });
    return json({ data: { transaction, server_knowledge: await repo.getServerKnowledge(targetPlanId) } }, 201);
  }

  if (segments[1] === "import" && segments[2] === "csv" && method === "POST") {
    const body = await readJson(request);
    const targetPlanId = body.plan_id ?? planId;
    const denied = authorizePlan(principal, targetPlanId, defaultPlanId, method);
    if (denied) return denied;
    await repo.ensurePlan(targetPlanId);
    const result = await importCsvRows(repo, targetPlanId, body.account_id, body.rows ?? []);
    return json({ data: result }, 201);
  }

  if (segments[1] === "import" && segments[2] === "ynab" && method === "POST") {
    const body = await readJson(request);
    const targetPlanId = body.plan_id ?? planId;
    const denied = authorizePlan(principal, targetPlanId, defaultPlanId, method);
    if (denied) return denied;
    await repo.ensurePlan(targetPlanId);
    const result = await importYnabFromApi(repo, {
      token: body.token,
      planId: targetPlanId,
      baseUrl: body.base_url,
      sinceDate: body.since_date,
    });
    return json({ data: result }, 201);
  }

  return apiError(404, "not_found", "Route not found");
}

function queryFilters(url: URL, overrides: Record<string, string | null> = {}): TransactionFilters {
  return {
    sinceDate: url.searchParams.get("since_date"),
    untilDate: url.searchParams.get("until_date"),
    type: url.searchParams.get("type"),
    accountId: overrides.accountId ?? null,
    payeeId: overrides.payeeId ?? null,
    categoryId: overrides.categoryId ?? null,
    month: overrides.month ? normaliseMonthStart(overrides.month) : null,
    lastKnowledgeOfServer: parseNumber(url.searchParams.get("last_knowledge_of_server")) ?? null,
    limit: parseTransactionPageNumber(url.searchParams.get("limit"), "limit", DEFAULT_TRANSACTION_PAGE_SIZE, 1, MAX_TRANSACTION_PAGE_SIZE),
    offset: parseTransactionPageNumber(url.searchParams.get("offset"), "offset", 0, 0),
  };
}

async function transactionListResponse(repo: LedgerStore, planId: string, filters: TransactionFilters): Promise<Response> {
  // The client uses server_knowledge to detect offset shifts while walking
  // pages. Read it on both sides of the page query so rows are never labelled
  // with a knowledge value from a concurrent write they do not contain.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const before = await repo.getServerKnowledge(planId);
    const page = await repo.listTransactionsPage(planId, filters);
    const after = await repo.getServerKnowledge(planId);
    if (before === after) {
      return json({
        data: {
          transactions: page.transactions,
          server_knowledge: after,
          has_more: page.has_more,
          next_offset: page.next_offset,
        },
      });
    }
  }
  return apiError(409, "ledger_changed", "Transactions changed while this page was loading. Try again.");
}

function parseTransactionPageNumber(
  value: string | null,
  name: "limit" | "offset",
  fallback: number,
  minimum: number,
  maximum = Number.MAX_SAFE_INTEGER,
): number {
  if (value == null) return fallback;
  if (!/^\d+$/.test(value)) throw new ValidationError(`${name} must be a whole number`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new ValidationError(`${name} must be between ${minimum} and ${maximum}`);
  }
  return parsed;
}

function reportFilters(url: URL) {
  return {
    from: url.searchParams.get("from"),
    to: url.searchParams.get("to"),
    accountIds: splitParam(url.searchParams.get("account_ids")),
    categoryIds: splitParam(url.searchParams.get("category_ids")),
    categoryGroupIds: splitParam(url.searchParams.get("category_group_ids")),
    payeeIds: splitParam(url.searchParams.get("payee_ids")),
    includeTransfers: url.searchParams.get("include_transfers") === "true",
    includeClosedAccounts: url.searchParams.get("include_closed_accounts") === "true",
    interval: (url.searchParams.get("interval") as any) ?? "month",
    topPayeesLimit: parseNumber(url.searchParams.get("top_payees_limit")),
  };
}

function splitParam(value: string | null): string[] {
  return value ? value.split(",").map((item) => item.trim()).filter(Boolean) : [];
}

function parseNumber(value: string | null): number | undefined {
  if (!value) {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function normaliseMonthStart(month: string): string {
  return month.length === 7 ? `${month}-01` : month;
}

async function readJson(request: Request): Promise<any> {
  const text = await request.text();
  if (!text) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ValidationError("Request body is not valid JSON");
  }
}

function scheduledWriteOptions(request: Request): { operationId?: string } {
  const key = request.headers.get("idempotency-key");
  if (key == null) return {};
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(key)) {
    throw new ValidationError("Idempotency-Key must be 8-128 letters, numbers, dots, underscores, colons, or hyphens");
  }
  return { operationId: `http_${sha256(key)}` };
}

function requireIdempotencyKey(request: Request): string {
  const options = scheduledWriteOptions(request);
  if (!options.operationId) throw new ValidationError("Idempotency-Key is required");
  return options.operationId;
}

async function handleAuth(request: Request, url: URL, store: AuthStore, config: ApiConfig): Promise<Response> {
  const path = url.pathname;
  const method = request.method.toUpperCase();

  if (path === "/api/auth/status" && method === "GET") {
    const principal = await authenticate(request, store, config.apiToken);
    const user = principal && principal.kind !== "api-token"
      ? { id: principal.id, username: principal.username }
      : null;
    return authJson({
      data: {
        setup_required: await store.setupRequired(),
        bootstrap_required: !!config.apiToken,
        user,
      },
    });
  }

  if (path === "/api/auth/personal-tokens" && method === "GET") {
    const principal = await authenticate(request, store, config.apiToken);
    if (!principal || principal.kind !== "session" || principal.transport !== "cookie") {
      return authError(401, "not_authorized", "A signed-in account is required");
    }
    return authJson({ data: { tokens: await store.listPersonalApiTokens(principal.id) } });
  }

  if (path === "/api/auth/personal-tokens" && method === "POST") {
    const principal = await authenticate(request, store, config.apiToken);
    if (!principal || principal.kind !== "session" || principal.transport !== "cookie") {
      return authError(401, "not_authorized", "A signed-in account is required");
    }
    if (!sameOrigin(request, url)) {
      return authError(403, "forbidden", "CSRF validation failed");
    }
    const body = await readJson(request);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name || name.length > 64 || /[\u0000-\u001f\u007f]/u.test(name)) {
      return authError(400, "bad_request", "Token name must be 1–64 visible characters");
    }
    const generated = newPersonalApiToken();
    const token = {
      id: generated.id,
      name,
      created_at: generated.createdAt,
      revoked_at: null,
    };
    await store.createPersonalApiToken({
      ...token,
      userId: principal.id,
      tokenHash: generated.tokenHash,
    });
    return authJson({ data: { token, value: generated.token } }, 201);
  }

  const tokenMatch = path.match(/^\/api\/auth\/personal-tokens\/([0-9a-f]{32})$/);
  if (tokenMatch && method === "DELETE") {
    const principal = await authenticate(request, store, config.apiToken);
    if (!principal || principal.kind !== "session" || principal.transport !== "cookie") {
      return authError(401, "not_authorized", "A signed-in account is required");
    }
    if (!sameOrigin(request, url)) {
      return authError(403, "forbidden", "CSRF validation failed");
    }
    const revoked = await store.revokePersonalApiToken(
      principal.id,
      tokenMatch[1],
      Math.floor(Date.now() / 1_000),
    );
    return revoked
      ? authJson({ data: { token: revoked } })
      : authError(404, "not_found", "API token not found");
  }

  if (path === "/api/auth/setup" && method === "POST") {
    if (!sameOrigin(request, url)) {
      return authError(403, "forbidden", "Origin validation failed");
    }
    const authorization = request.headers.get("authorization");
    const validBootstrap = config.apiToken
      ? authorization?.startsWith("Bearer ") && safeTokenEqual(authorization.slice(7), config.apiToken)
      : authorization === null;
    if (!validBootstrap) {
      return authError(401, "not_authorized", "Invalid bootstrap token");
    }

    const body = await readJson(request);
    const username = canonicalUsername(body.username);
    if (!username || !validPassword(body.password)) {
      return authError(400, "bad_request", "Username or password does not meet the requirements");
    }

    const userId = randomBytes(16).toString("hex");
    const session = newSession();
    const credential = await passwordCredential(body.password);
    const created = await store.setup({
      userId,
      username,
      credential,
      session,
      planId: config.defaultPlanId,
    });
    if (!created) {
      return authError(409, "setup_complete", "Setup has already completed");
    }
    return sessionResponse({ data: { user: { id: userId, username } } }, session.token, session.expiresAt);
  }

  if ((path === "/api/auth/login" || path === "/api/auth/token") && method === "POST") {
    const browserLogin = path === "/api/auth/login";
    if (browserLogin && !sameOrigin(request, url)) {
      return authError(403, "forbidden", "Origin validation failed");
    }

    const body = await readJson(request);
    const username = canonicalUsername(body.username);
    const suppliedPassword = typeof body.password === "string" ? body.password : "";
    const windowStart = Math.floor(Date.now() / 1_000 / 900) * 900;
    const clientIp = request.headers.get("cf-connecting-ip") ?? "unknown";
    const usernameAttempts = await store.rateAttempt("username", sha256(username ?? "invalid"), windowStart);
    const ipAttempts = await store.rateAttempt("ip", sha256(clientIp), windowStart);
    if (usernameAttempts > 10 || ipAttempts > 50) {
      return authError(429, "rate_limited", "Too many login attempts", { "retry-after": "900" });
    }

    const credential = username ? await store.credential(username) : null;
    const valid = validPassword(suppliedPassword) && await verifyPassword(suppliedPassword, credential);
    if (!valid || !credential) {
      return authError(401, "invalid_credentials", "Invalid username or password");
    }

    const session = newSession();
    await store.createSession(credential.user_id, session);
    const user = { id: credential.user_id, username: credential.username };
    return browserLogin
      ? sessionResponse({ data: { user } }, session.token, session.expiresAt)
      : authJson({ data: { token: session.token, expires_at: session.expiresAt, user } });
  }

  if (path === "/api/auth/logout" && method === "POST") {
    const principal = await authenticate(request, store, config.apiToken);
    if (!principal || principal.kind !== "session") {
      return authError(401, "not_authorized", "Invalid session");
    }
    if (principal.transport === "cookie" && !sameOrigin(request, url)) {
      return authError(403, "forbidden", "CSRF validation failed");
    }
    const token = principal.transport === "bearer"
      ? request.headers.get("authorization")!.slice(7)
      : cookieToken(request)!;
    await store.revokeSession(sha256(token), Math.floor(Date.now() / 1_000));
    return clearSessionResponse({ data: { ok: true } });
  }

  return authError(404, "not_found", "Route not found");
}

async function authenticate(request: Request, store: AuthStore, apiToken?: string): Promise<Principal | null> {
  const authorization = request.headers.get("authorization");
  if (authorization !== null) {
    if (!authorization.startsWith("Bearer ")) return null;
    const token = authorization.slice(7);
    if (apiToken && safeTokenEqual(token, apiToken)) return { kind: "api-token" };
    const tokenHash = sha256(token);
    const user = await store.authenticateSession(tokenHash, Math.floor(Date.now() / 1_000));
    if (user) return { kind: "session", transport: "bearer", ...user };
    const tokenUser = token.startsWith("hm_pat_")
      ? await store.authenticatePersonalApiToken(tokenHash)
      : null;
    return tokenUser ? { kind: "personal-token", ...tokenUser } : null;
  }

  const token = cookieToken(request);
  if (!token) return null;
  const user = await store.authenticateSession(sha256(token), Math.floor(Date.now() / 1_000));
  return user ? { kind: "session", transport: "cookie", ...user } : null;
}

function cookieToken(request: Request): string | null {
  const match = request.headers.get("cookie")?.match(/(?:^|;\s*)__Host-howmuch_session=([^;]+)/);
  return match?.[1] ?? null;
}

function sameOrigin(request: Request, url: URL): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none") return false;
  const origin = request.headers.get("origin");
  if (origin) return origin !== "null" && origin === url.origin;
  const referer = request.headers.get("referer");
  if (!referer) return false;
  try {
    return new URL(referer).origin === url.origin;
  } catch {
    return false;
  }
}

function isUnsafeMethod(method: string): boolean {
  return !["GET", "HEAD", "OPTIONS"].includes(method.toUpperCase());
}

function isTransitionFinancialWrite(methodValue: string, segments: string[]): boolean {
  const method = methodValue.toUpperCase();

  if (segments[0] === "api" && segments.length === 3 && method === "POST") {
    return (segments[1] === "mobile" && segments[2] === "quick-entry")
      || (segments[1] === "import" && (segments[2] === "csv" || segments[2] === "ynab"));
  }

  if (segments[0] !== "v1" || (segments[1] !== "plans" && segments[1] !== "budgets")) {
    return false;
  }

  const resource = segments[3];
  if ((resource === "accounts" || resource === "payees") && segments.length === 4) {
    return method === "POST";
  }
  if (resource === "accounts" && segments.length === 6 && segments[5] === "reconcile") {
    return method === "POST";
  }
  if (resource === "transactions") {
    if (segments.length === 4) return method === "POST" || method === "PATCH";
    if (segments.length === 5 && segments[4] === "import") return method === "POST";
    if (segments.length === 5) return method === "PUT" || method === "PATCH" || method === "DELETE";
    return false;
  }
  if (resource === "scheduled_transactions") {
    if (segments.length === 4) return method === "POST";
    if (segments.length === 5 && segments[4] === "materialize") return method === "POST";
    if (segments.length === 5) return method === "PUT" || method === "PATCH" || method === "DELETE";
    if (segments.length === 6 && segments[5] === "materialize") return method === "POST";
    return false;
  }
  return resource === "months"
    && segments.length === 7
    && segments[5] === "categories"
    && method === "PATCH";
}

function canRead(principal: Principal, planId: string, defaultPlanId: string): boolean {
  return principal.kind === "api-token"
    ? planId === defaultPlanId
    : Object.prototype.hasOwnProperty.call(principal.roles, planId);
}

function authorizePlan(principal: Principal, planId: string, defaultPlanId: string, method: string): Response | null {
  if (!canRead(principal, planId, defaultPlanId)) {
    return apiError(404, "resource_not_found", "Plan not found", "404.2");
  }
  if (principal.kind !== "api-token" && isUnsafeMethod(method) && principal.roles[planId] === "viewer") {
    return apiError(403, "forbidden", "Plan is read-only");
  }
  return null;
}

function authorizePlanAdministration(principal: Principal, planId: string): Response | null {
  if (principal.kind !== "api-token" && principal.roles[planId] !== "owner") {
    return apiError(403, "forbidden", "Plan owner access is required");
  }
  return null;
}

function authJson(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  const response = json(body, status);
  response.headers.set("cache-control", "no-store");
  for (const [key, value] of Object.entries(headers)) response.headers.set(key, value);
  return response;
}

function authError(status: number, name: string, detail: string, headers: Record<string, string> = {}): Response {
  const response = apiError(status, name, detail);
  response.headers.set("cache-control", "no-store");
  for (const [key, value] of Object.entries(headers)) response.headers.set(key, value);
  return response;
}

function sessionResponse(body: unknown, token: string, expiresAt: number): Response {
  const response = authJson(body);
  const maxAge = Math.max(0, expiresAt - Math.floor(Date.now() / 1_000));
  response.headers.set(
    "set-cookie",
    `__Host-howmuch_session=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=${maxAge}`,
  );
  return response;
}

function clearSessionResponse(body: unknown): Response {
  const response = authJson(body);
  response.headers.set(
    "set-cookie",
    "__Host-howmuch_session=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0",
  );
  return response;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function apiError(status: number, name: string, detail: string, id = String(status)): Response {
  return json(
    {
      error: {
        id,
        name,
        detail,
      },
    },
    status,
  );
}
