import type { Database } from "bun:sqlite";
import type { ApiConfig } from "./config";
import { AccountPreferencesConflictError, LedgerRepository, NotFoundError, ReconciliationMismatchError, TransactionStateConflictError, ValidationError } from "./repository";
import { MAX_REGISTER_QUERY_LENGTH } from "@howmuch/register-query";
import { DEFAULT_TRANSACTION_PAGE_SIZE, MAX_TRANSACTION_PAGE_SIZE, type AccountPreferences, type TransactionFilters } from "./types";
import { collectionPostIntent, parseTransactionClearedBulk, parseTransactionCreates, parseTransactionDeleteBulk, parseTransactionUpdates } from "./transaction-batch";
import { ReportService } from "./reports";
import { decimalToMilliunits } from "./money";
import { importCsvRows } from "./importers/csv";
import { importRewardsTrackerExport } from "./importers/rewards-tracker";
import { importYnabFromApi } from "./importers/ynab";
import { parseRewardGroupBy } from "./rewards/parse";
import { exportRewardsAccountConfig, importRewardsAccountConfig } from "./rewards/account-config";
import {
  createRewardsCard,
  deleteRewardsCard,
  patchRewardsCard,
  patchRewardsSettings,
  RewardsAccountError,
  stampTransactionFlagName,
} from "./rewards/write";
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
import { ACCOUNT_KINDS, parseAccountKind, type AccountUpdatePatch } from "./account-kind";
import { handleRewardTool } from "./reward-tools";
import { autoCategorise, CategoriserUnavailableError, parseCategoriseExclusions, parseCategoriseItems, suggestCategories, type CategoriserConfig } from "./categoriser";
import type { Fetch } from "@typesafe-ai/sdk";

type HandlerOptions = {
  db?: Database;
  repo?: LedgerStore;
  reports?: ReportStore;
  auth?: AuthStore;
  config: ApiConfig;
  /** Transport for TypeSafe requests; tests substitute it. */
  typesafeFetch?: Fetch;
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

      const categoriser: CategoriserConfig = {
        apiKey: config.typesafeApiKey,
        model: config.typesafeModel,
        fetch: options.typesafeFetch,
      };

      if (segments[0] === "v1") {
        return await handleV1(request, url, segments, repo, principal, config.defaultPlanId, config.transitionReadOnly, categoriser);
      }

      if (segments[0] === "api") {
        return await handleNative(request, url, segments, repo, reports, principal, config.defaultPlanId, categoriser);
      }

      return apiError(404, "not_found", "Route not found");
    } catch (error) {
      if (error instanceof NotFoundError) {
        return apiError(404, "resource_not_found", error.message, "404.2");
      }
      if (error instanceof ValidationError) {
        return apiError(400, "bad_request", error.message);
      }
      if (error instanceof RewardsAccountError) {
        return apiError(422, "unprocessable_entity", error.message);
      }
      if (error instanceof TransactionStateConflictError) {
        return apiError(409, "transaction_state_conflict", error.message);
      }
      if (error instanceof AccountPreferencesConflictError) {
        return apiError(409, "account_preferences_conflict", "Account preferences changed on another client");
      }
      if (error instanceof CategoriserUnavailableError) {
        return apiError(error.status, error.code, error.message);
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
  transitionReadOnly: boolean,
  categoriser: CategoriserConfig,
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
  const isAccountPreferencesRoute = segments.length === 4 && segments[3] === "account_preferences";
  const denied = isAccountPreferencesRoute
    ? (!canRead(principal, planId, defaultPlanId) ? apiError(404, "resource_not_found", "Plan not found", "404.2") : null)
    : authorizePlan(principal, planId, defaultPlanId, method);
  if (denied) return denied;
  // Reads never create the plan they name: a missing plan is a 404, not an
  // implicit INSERT on the D1 primary. Writes still bootstrap it, because an
  // API-token client may address the default plan before setup has run.
  if (isUnsafeMethod(method)) await repo.ensurePlan(planId);

  if (segments.length === 3 && method === "GET") {
    const plan = await repo.getPlan(planId);
    return json({ data: isBudgetAlias ? { budget: plan } : { plan } });
  }

  const resource = segments[3];

  if (resource === "settings" && segments.length === 4 && method === "GET") {
    return json({ data: { settings: await repo.getSettings(planId) } });
  }

  if (resource === "account_preferences" && segments.length === 4) {
    if (principal.kind === "api-token") {
      return apiError(403, "forbidden", "Account preferences require a user-scoped credential");
    }
    if (method === "GET") {
      return json({ data: await repo.getAccountPreferences(planId, principal.id) });
    }
    if (method === "PUT") {
      const body = await readJson(request);
      const preferences = parseAccountPreferences(body.account_preferences);
      if (!Number.isSafeInteger(body.expected_revision) || body.expected_revision < 0) {
        throw new ValidationError("expected_revision must be a non-negative integer");
      }
      return json({ data: await repo.setAccountPreferences(planId, principal.id, preferences, body.expected_revision) });
    }
  }

  if (resource === "accounts") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: await repo.listAccountsWithKnowledge(planId) });
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
    // Must precede the `/accounts/{account_id}` branch below, or "usage" would
    // be read as an account id.
    if (segments.length === 5 && segments[4] === "usage" && method === "GET") {
      const window = parseAccountUsageWindow(url);
      const usage = await repo.accountUsage(planId, window.since, window.until);
      return json({ data: { ...usage, days: window.days } });
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
    if (segments.length === 5 && (method === "PATCH" || method === "PUT")) {
      const body = await readJson(request);
      const payload = body.account ?? body;
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        throw new ValidationError("account.icon, account.name, or account.type is required");
      }
      if (Object.prototype.hasOwnProperty.call(payload, "on_budget")) {
        throw new ValidationError("account.on_budget is derived from account.type and cannot be set");
      }
      const kind = payload.type === undefined ? undefined : parseAccountKind(payload.type);
      if (payload.type !== undefined && kind === null) {
        throw new ValidationError(`account.type must be one of ${Object.keys(ACCOUNT_KINDS).join(", ")}`);
      }
      const patch: AccountUpdatePatch = {
        ...(typeof payload.icon === "string" ? { icon: payload.icon } : {}),
        ...(typeof payload.name === "string" ? { name: payload.name } : {}),
        ...(kind ? { kind } : {}),
      };
      if (patch.icon === undefined && patch.name === undefined && patch.kind === undefined) {
        throw new ValidationError("account.icon, account.name, or account.type is required");
      }
      if (transitionReadOnly && patch.kind !== undefined) {
        return apiError(
          423,
          "transition_read_only",
          "Financial changes are temporarily locked while YNAB is the source of truth",
        );
      }
      const account = await repo.updateAccount(planId, accountId, patch);
      return json({ data: { account, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { accountId }));
    }
    if (segments.length === 7 && segments[5] === "transactions" && segments[6] === "unapproved_count" && method === "GET") {
      return unapprovedCountResponse(repo, planId, countFilters(url, { accountId }));
    }
  }

  if (resource === "categories" && segments.length === 4 && method === "GET") {
    return json({ data: await repo.listCategoryGroupsWithKnowledge(planId) });
  }
  if (resource === "categories") {
    const categoryId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return transactionListResponse(repo, planId, queryFilters(url, { categoryId }));
    }
  }

  if (resource === "payees") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: await repo.listPayeesWithKnowledge(planId) });
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
      return json({ data: await repo.listScheduledTransactionsWithKnowledge(planId) });
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

  // Payee locations have no normalised write model yet. The raw mirror makes
  // them available to clients switching over without discarding them. YNAB
  // money movements are budgeting data: the importer still mirrors them, but
  // HowMuch has no budgeting and no longer serves them.
  const sourceOnlyCollections: Record<string, { type: string; field: string }> = {
    payee_locations: { type: "payee_location", field: "payee_locations" },
  };
  const sourceOnly = sourceOnlyCollections[resource];
  if (sourceOnly && segments.length === 4 && method === "GET") {
    const sourceObjects = await repo.listYnabRawObjects(planId, sourceOnly.type);
    return json({ data: { [sourceOnly.field]: sourceObjects, server_knowledge: await repo.getServerKnowledge(planId) } });
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
        const inputs = parseTransactionCreates(body.transactions);
        await autoCategorise(repo, planId, inputs, categoriser);
        const result = await repo.createTransactions(planId, inputs);
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
        await stampTransactionFlagName(repo, planId, input.account_id, input);
        await autoCategorise(repo, planId, [input], categoriser);
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

    // Must precede the item route below: "unapproved_count" is a path segment,
    // not a transaction id.
    if (segments.length === 5 && segments[4] === "unapproved_count" && method === "GET") {
      return unapprovedCountResponse(repo, planId, countFilters(url));
    }

    // Bulk commands are also path segments, and must precede the item route.
    // Each returns ordered per-item outcomes rather than promising atomicity:
    // a D1 command commits row by row, so the caller has to be told which rows
    // are confirmed, which conflicted, and which were never attempted.
    if (segments.length === 5 && segments[4] === "cleared" && method === "POST") {
      const result = await repo.updateTransactionsCleared(planId, parseTransactionClearedBulk(await readJson(request)));
      return json({ data: result });
    }
    if (segments.length === 5 && segments[4] === "delete" && method === "POST") {
      const result = await repo.deleteTransactions(planId, parseTransactionDeleteBulk(await readJson(request)));
      return json({ data: result });
    }

    const { transactionId, expectedApprovedParameter } = transactionItemRef(segments[4], url);
    if (segments.length === 5 && method === "GET") {
      return json({ data: { transaction: await repo.getTransaction(planId, transactionId), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "cleared" && method === "PATCH") {
      const body = await readJson(request);
      if (!isToggleClearedState(body.expected_cleared) || !isToggleClearedState(body.cleared)) {
        throw new ValidationError("expected_cleared and cleared must be uncleared or cleared");
      }
      const updated = await repo.updateTransactionCleared(planId, transactionId, body.expected_cleared, body.cleared);
      return json({ data: { transaction: updated, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && (method === "PUT" || method === "PATCH")) {
      const body = await readJson(request);
      const patch = body.transaction ?? body;
      if (Object.prototype.hasOwnProperty.call(patch, "flag_color") && !Object.prototype.hasOwnProperty.call(patch, "flag_name")) {
        const existing = await repo.getTransaction(planId, transactionId);
        await stampTransactionFlagName(repo, planId, existing.account_id, patch);
      }
      const updated = await repo.updateTransaction(planId, transactionId, patch);
      return json({ data: { transaction: updated, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && method === "DELETE") {
      if (expectedApprovedParameter !== null && expectedApprovedParameter !== "true" && expectedApprovedParameter !== "false") {
        throw new ValidationError("expected_approved must be true or false");
      }
      const expectedApproved = expectedApprovedParameter === null ? undefined : expectedApprovedParameter === "true";
      const deleted = await repo.deleteTransaction(planId, transactionId, expectedApproved);
      return json({ data: { transaction: deleted, server_knowledge: await repo.getServerKnowledge(planId) } });
    }
  }

  return apiError(404, "not_found", "Route not found");
}

function parseAccountPreferences(value: unknown): AccountPreferences {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError("account_preferences is required");
  }
  const input = value as Record<string, unknown>;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > 65_536) {
    throw new ValidationError("account_preferences is too large");
  }
  const strings = (field: unknown, name: string): string[] => {
    if (!Array.isArray(field) || field.length > 500 || field.some((item) => typeof item !== "string" || !item || item.length > 200)) {
      throw new ValidationError(`${name} must be an array of non-empty strings`);
    }
    if (new Set(field).size !== field.length) throw new ValidationError(`${name} must not contain duplicates`);
    return field as string[];
  };
  const orderByGroup: Record<string, string[]> = Object.create(null);
  if (!input.account_order_by_group || typeof input.account_order_by_group !== "object" || Array.isArray(input.account_order_by_group)) {
    throw new ValidationError("account_order_by_group must be an object");
  }
  const orderEntries = Object.entries(input.account_order_by_group);
  if (orderEntries.length > 100) throw new ValidationError("account_order_by_group has too many entries");
  for (const [groupId, order] of orderEntries) {
    if (!validPreferenceKey(groupId)) throw new ValidationError("account group IDs must be canonical non-empty strings");
    orderByGroup[groupId] = strings(order, "account group order");
  }
  if (!input.account_group_sorts || typeof input.account_group_sorts !== "object" || Array.isArray(input.account_group_sorts)) {
    throw new ValidationError("account_group_sorts must be an object");
  }
  const sorts: AccountPreferences["account_group_sorts"] = Object.create(null);
  const sortEntries = Object.entries(input.account_group_sorts);
  if (sortEntries.length > 100) throw new ValidationError("account_group_sorts has too many entries");
  for (const [groupId, sort] of sortEntries) {
    if (!validPreferenceKey(groupId) || !["manual", "alphabetical", "mostUsedLast30Days"].includes(String(sort))) {
      throw new ValidationError("account group sorts are invalid");
    }
    sorts[groupId] = sort as AccountPreferences["account_group_sorts"][string];
  }
  if (!Array.isArray(input.custom_account_groups) || input.custom_account_groups.length > 100) {
    throw new ValidationError("custom_account_groups must be an array");
  }
  const usedGroupIDs = new Set<string>();
  const usedGroupNames = new Set<string>();
  const reserved = new Set(["favourites", "cash", "credit", "tracking", "closed"]);
  const dangerous = new Set(["__proto__", "prototype", "constructor"]);
  const customGroups = input.custom_account_groups.map((group) => {
    if (!group || typeof group !== "object" || Array.isArray(group)) throw new ValidationError("custom account groups are invalid");
    const candidate = group as Record<string, unknown>;
    if (typeof candidate.id !== "string" || !validPreferenceKey(candidate.id)
      || typeof candidate.name !== "string" || !candidate.name.trim() || candidate.name.length > 100) {
      throw new ValidationError("custom account groups are invalid");
    }
    const idKey = candidate.id.toLowerCase();
    const nameKey = canonicalAccountGroupName(candidate.name);
    if (reserved.has(idKey) || dangerous.has(idKey) || reserved.has(nameKey)
      || usedGroupIDs.has(idKey) || usedGroupNames.has(nameKey)) {
      throw new ValidationError("custom account group IDs and names must be unique and non-reserved");
    }
    usedGroupIDs.add(idKey);
    usedGroupNames.add(nameKey);
    return { id: candidate.id, name: candidate.name.trim(), account_ids: strings(candidate.account_ids, "custom group account_ids") };
  });
  const validGroupIDs = new Set([...reserved, ...customGroups.map((group) => group.id)]);
  if (orderEntries.some(([key]) => !validGroupIDs.has(key)) || sortEntries.some(([key]) => !validGroupIDs.has(key))) {
    throw new ValidationError("account preference maps contain an unknown group ID");
  }
  return {
    favourite_account_ids: strings(input.favourite_account_ids, "favourite_account_ids"),
    account_order: strings(input.account_order, "account_order"),
    account_order_by_group: orderByGroup,
    account_group_sorts: sorts,
    custom_account_groups: customGroups,
  };
}

function canonicalAccountGroupName(name: string): string {
  return name.trim().normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase();
}

function validPreferenceKey(value: string): boolean {
  return Boolean(value) && value.length <= 200 && value === value.trim()
    && !["__proto__", "prototype", "constructor"].includes(value.toLowerCase());
}

async function handleNative(
  request: Request,
  url: URL,
  segments: string[],
  repo: LedgerStore,
  reports: ReportStore,
  principal: Principal,
  defaultPlanId: string,
  categoriser: CategoriserConfig,
): Promise<Response> {
  const method = request.method.toUpperCase();
  const planId = url.searchParams.get("plan_id") ?? defaultPlanId;

  // Suggestions only: nothing is written. Cookie sessions still pass the
  // global same-origin check for POSTs, and bearer clients (iOS) may call it.
  if (segments[1] === "tools" && segments[2] === "categorise" && segments.length === 3 && method === "POST") {
    const denied = authorizePlan(principal, planId, defaultPlanId, method);
    if (denied) return denied;
    const body = await readJson(request);
    const items = parseCategoriseItems(body);
    const excluded = parseCategoriseExclusions(body);
    return json({ data: await suggestCategories(repo, planId, items, categoriser, undefined, excluded) });
  }

  if (segments[1] === "tools" && segments.length === 3 && method === "POST"
    && ["reward-terms", "statement-formatter"].includes(segments[2])) {
    if (!sameOrigin(request, url)) return apiError(403, "forbidden", "CSRF validation failed");
    const denied = authorizePlan(principal, planId, defaultPlanId, method);
    if (denied) return denied;
    return handleRewardTool(request, segments[2]);
  }

  if (segments[1] === "reports" && method === "GET") {
    const denied = authorizePlan(principal, planId, defaultPlanId, method);
    if (denied) return denied;
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
    if (segments[2] === "rewards") {
      return json({ data: await reports.rewards(planId, filters) });
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
    const input = {
      id: body.client_id,
      account_id: body.account_id,
      date: body.date ?? new Date().toISOString().slice(0, 10),
      amount,
      payee_id: body.payee_id ?? null,
      payee_name: body.payee_name ?? body.payee ?? null,
      category_id: body.category_id ?? null,
      memo: body.memo ?? null,
      flag_color: body.flag_color ?? null,
      approved: true,
      source_kind: "mobile",
      source_ref: body.client_id ?? null,
      subtransactions,
    };
    await stampTransactionFlagName(repo, targetPlanId, input.account_id, input);
    await autoCategorise(repo, targetPlanId, [input], categoriser);
    const transaction = await repo.createTransaction(targetPlanId, input);
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

  if (segments[1] === "import" && segments[2] === "rewards-tracker") {
    const denied = authorizePlan(principal, planId, defaultPlanId, method);
    if (denied) return denied;
    if (method === "GET") {
      return json({ data: await repo.getRewardsTrackerSnapshot(planId) });
    }
    if (method === "POST") {
      const body = await readJson(request);
      const targetPlanId = body.plan_id ?? planId;
      const targetDenied = authorizePlan(principal, targetPlanId, defaultPlanId, method);
      if (targetDenied) return targetDenied;
      await repo.ensurePlan(targetPlanId);
      const payload = rewardsTrackerPayload(body);
      const result = await importRewardsTrackerExport(repo, targetPlanId, payload);
      return json({ data: result }, 201);
    }
  }

  if (segments[1] === "rewards") {
    const body = isUnsafeMethod(method) ? await readJson(request) : {};
    const targetPlanId = body.plan_id ?? planId;
    const denied = authorizePlan(principal, targetPlanId, defaultPlanId, method);
    if (denied) return denied;
    // Reads must not create a plan as a side effect.
    if (isUnsafeMethod(method)) await repo.ensurePlan(targetPlanId);

    if (segments[2] === "accounts" && segments[4] === "config" && segments.length === 5) {
      let accountId: string;
      try { accountId = decodeURIComponent(segments[3]); }
      catch { throw new ValidationError("Invalid account ID encoding"); }
      if (method === "GET") return json({ data: await exportRewardsAccountConfig(repo, targetPlanId, accountId) });
      if (method === "PUT") {
        const card = await importRewardsAccountConfig(repo, targetPlanId, accountId, body.payload);
        return json({ data: { card } });
      }
    }
    if (segments[2] === "cards" && segments.length === 3 && method === "POST") {
      const card = await createRewardsCard(repo, targetPlanId, body.card);
      return json({ data: { card } }, 201);
    }
    if (segments[2] === "cards" && segments.length === 4 && method === "PATCH") {
      const card = await patchRewardsCard(repo, targetPlanId, segments[3], body.card);
      return json({ data: { card } });
    }
    if (segments[2] === "cards" && segments.length === 4 && method === "DELETE") {
      const card = await deleteRewardsCard(repo, targetPlanId, segments[3]);
      return json({ data: { card } });
    }
    if (segments[2] === "settings" && segments.length === 3 && method === "PATCH") {
      const settings = await patchRewardsSettings(repo, targetPlanId, body);
      return json({ data: { settings } });
    }
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
    q: parseRegisterQueryParam(url.searchParams.get("q")),
  };
}

async function transactionListResponse(repo: LedgerStore, planId: string, filters: TransactionFilters): Promise<Response> {
  // The client uses server_knowledge to detect offset shifts while walking
  // pages. listTransactionsPage reads the knowledge value in the same batch as
  // the rows, and a batch is one transaction, so the label already describes
  // exactly these rows. That replaces the old read-either-side-and-retry loop.
  const page = await repo.listTransactionsPage(planId, filters);
  return json({
    data: {
      transactions: page.transactions,
      server_knowledge: page.server_knowledge,
      has_more: page.has_more,
      next_offset: page.next_offset,
    },
  });
}

/**
 * Filters a count understands. Deliberately not `queryFilters`: `limit` and
 * `offset` page a list and have nothing to page here, so rejecting a caller's
 * stray `limit=0` would be a 400 about a parameter the route ignores.
 */
function countFilters(url: URL, overrides: Record<string, string | null> = {}): TransactionFilters {
  return {
    sinceDate: url.searchParams.get("since_date"),
    untilDate: url.searchParams.get("until_date"),
    accountId: overrides.accountId ?? null,
  };
}

/**
 * The "New" badge without the queue behind it. Clients used to page the entire
 * unapproved queue to render a number; this answers the number in one D1 round
 * trip and lets them fetch the rows only when the approval flow is opened.
 */
async function unapprovedCountResponse(repo: LedgerStore, planId: string, filters: TransactionFilters): Promise<Response> {
  return json({ data: await repo.countUnapprovedTransactions(planId, filters) });
}

function parseRegisterQueryParam(value: string | null): string | null {
  if (value == null) {
    return null;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  if (trimmed.length > MAX_REGISTER_QUERY_LENGTH) {
    throw new ValidationError(`q must be at most ${MAX_REGISTER_QUERY_LENGTH} characters`);
  }
  return trimmed;
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
    groupBy: parseRewardGroupBy(url.searchParams.get("group")),
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

function rewardsTrackerPayload(body: Record<string, unknown>): unknown {
  if (typeof body.payload === "string") {
    try {
      return JSON.parse(body.payload);
    } catch {
      throw new ValidationError("Rewards Tracker export is not valid JSON");
    }
  }
  if (body.payload && typeof body.payload === "object") {
    return body.payload;
  }
  const { plan_id: _planId, ...exportBody } = body;
  return exportBody;
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
        // Unix seconds. The web client stores this and refuses to paint cached
        // ledger data once it has passed, so an expired cookie cannot show the
        // previous user's plan to whoever opens the browser next (#175, #177).
        session_expires_at: principal?.kind === "session" ? principal.sessionExpiresAt ?? null : null,
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
    const bootstrapToken = bearerToken(authorization);
    const validBootstrap = config.apiToken
      ? bootstrapToken !== null && safeTokenEqual(bootstrapToken, config.apiToken)
      : authorization === null;
    if (!validBootstrap) {
      return authError(401, "not_authorized", "Invalid setup token");
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
    return sessionResponse({ data: { user: { id: userId, username }, session_expires_at: session.expiresAt } }, session.token, session.expiresAt);
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
      ? sessionResponse({ data: { user, session_expires_at: session.expiresAt } }, session.token, session.expiresAt)
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
      ? bearerToken(request.headers.get("authorization"))!
      : cookieToken(request)!;
    await store.revokeSession(sha256(token), Math.floor(Date.now() / 1_000));
    return clearSessionResponse({ data: { ok: true } });
  }

  return authError(404, "not_found", "Route not found");
}

async function authenticate(request: Request, store: AuthStore, apiToken?: string): Promise<Principal | null> {
  const authorization = request.headers.get("authorization");
  if (authorization !== null) {
    const token = bearerToken(authorization);
    if (token === null) return null;
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

function bearerToken(authorization: string | null): string | null {
  const match = authorization?.match(/^Bearer ([^\s]+)$/i);
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
      || (segments[1] === "import" && (segments[2] === "csv" || segments[2] === "ynab" || segments[2] === "rewards-tracker"));
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
    if (segments.length === 5 && (segments[4] === "cleared" || segments[4] === "delete")) return method === "POST";
    if (segments.length === 5) return method === "PUT" || method === "PATCH" || method === "DELETE";
    if (segments.length === 6 && segments[5] === "cleared") return method === "PATCH";
    return false;
  }
  if (resource === "scheduled_transactions") {
    if (segments.length === 4) return method === "POST";
    if (segments.length === 5 && segments[4] === "materialize") return method === "POST";
    if (segments.length === 5) return method === "PUT" || method === "PATCH" || method === "DELETE";
    if (segments.length === 6 && segments[5] === "materialize") return method === "POST";
    return false;
  }
  return false;
}

function isToggleClearedState(value: unknown): value is "uncleared" | "cleared" {
  return value === "uncleared" || value === "cleared";
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

/**
 * iOS used to concatenate `?expected_approved=` onto the path. `encodedPath`
 * then percent-encodes `?` as `%3F`, so the last segment is `id%3Fexpected_approved=false`
 * and a lookup of that string 404s. Split the embedded query back out.
 */
function transactionItemRef(segment: string, url: URL): { transactionId: string; expectedApprovedParameter: string | null } {
  let decoded = segment;
  try {
    decoded = decodeURIComponent(segment);
  } catch {
    decoded = segment;
  }
  const cut = decoded.indexOf("?");
  const transactionId = cut === -1 ? decoded : decoded.slice(0, cut);
  const embedded = cut === -1 ? new URLSearchParams() : new URLSearchParams(decoded.slice(cut + 1));
  return {
    transactionId,
    expectedApprovedParameter: url.searchParams.get("expected_approved") ?? embedded.get("expected_approved"),
  };
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

const MAX_ACCOUNT_USAGE_DAYS = 366;

/**
 * The account-usage window is client-defined: the caller passes the last day it
 * means by "today" in its own time zone, and the count of days to include. The
 * server only defaults `until` to the current UTC date and arithmetic stays in
 * UTC so a daylight-saving shift cannot move the boundary.
 */
function parseAccountUsageWindow(url: URL): { days: number; since: string; until: string } {
  const rawDays = url.searchParams.get("days");
  const days = rawDays === null ? 30 : Number(rawDays);
  if (!/^\d+$/.test(rawDays ?? "30") || !Number.isSafeInteger(days) || days < 1 || days > MAX_ACCOUNT_USAGE_DAYS) {
    throw new ValidationError(`days must be an integer between 1 and ${MAX_ACCOUNT_USAGE_DAYS}`);
  }
  const rawUntil = url.searchParams.get("until");
  const until = rawUntil ?? new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(until)) {
    throw new ValidationError("until must be an ISO date (YYYY-MM-DD)");
  }
  const untilMs = Date.parse(`${until}T00:00:00Z`);
  if (!Number.isFinite(untilMs) || new Date(untilMs).toISOString().slice(0, 10) !== until) {
    throw new ValidationError("until must be a valid calendar date");
  }
  return { days, since: new Date(untilMs - (days - 1) * 86_400_000).toISOString().slice(0, 10), until };
}
