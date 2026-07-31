import type { Database } from "bun:sqlite";
import type { ApiConfig } from "./config";
import { LedgerRepository, NotFoundError, ValidationError } from "./repository";
import { ReportService } from "./reports";
import { decimalToMilliunits } from "./money";
import { importCsvRows } from "./importers/csv";
import { importYnabFromApi } from "./importers/ynab";
import type { LedgerStore, ReportStore } from "./storage";
import { SQLiteAuthStore, type AuthStore, type AuthUser } from "./auth-store";
import {
  canonicalUsername,
  newSession,
  passwordCredential,
  safeTokenEqual,
  sha256,
  validPassword,
  verifyPassword,
} from "./password-auth";
import { randomBytes } from "node:crypto";

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
      console.error("Unhandled API error", error);
      return apiError(500, "internal_server_error", "An internal error occurred");
    }
  };
}

type Principal = { kind: "api-token" } | ({ kind: "session"; transport: "cookie" | "bearer" } & AuthUser);

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
    const user = principal.kind === "session"
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
    if (segments.length === 5 && method === "GET") {
      return json({ data: { account: await repo.getAccount(planId, accountId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: await repo.listTransactions(planId, queryFilters(url, { accountId })),
          server_knowledge: await repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "categories" && segments.length === 4 && method === "GET") {
    return json({ data: { category_groups: await repo.listCategoryGroups(planId), server_knowledge: await repo.getServerKnowledge(planId) } });
  }
  if (resource === "categories") {
    const categoryId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: await repo.listTransactions(planId, queryFilters(url, { categoryId })),
          server_knowledge: await repo.getServerKnowledge(planId),
        },
      });
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
      return json({
        data: {
          transactions: await repo.listTransactions(planId, queryFilters(url, { payeeId })),
          server_knowledge: await repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "months") {
    const month = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { month: await repo.getMonth(planId, month), server_knowledge: await repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: await repo.listTransactions(planId, queryFilters(url, { month })),
          server_knowledge: await repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "transactions") {
    if (segments.length === 4 && method === "GET") {
      return json({
        data: {
          transactions: await repo.listTransactions(planId, queryFilters(url)),
          server_knowledge: await repo.getServerKnowledge(planId),
        },
      });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      const input = body.transaction;
      if (!input) {
        return apiError(400, "bad_request", "transaction is required");
      }
      const duplicate = input?.import_id ? await repo.findDuplicateTransaction(planId, input) : null;
      if (duplicate) {
        return json({
          data: {
            transaction: duplicate,
            transaction_ids: [duplicate.id],
            duplicate_import_ids: [input.import_id],
            server_knowledge: await repo.getServerKnowledge(planId),
          },
        });
      }
      const created = await repo.createTransaction(planId, input);
      return json({ data: { transaction: created, transaction_ids: [created.id], server_knowledge: await repo.getServerKnowledge(planId) } }, 201);
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

function queryFilters(url: URL, overrides: Record<string, string | null> = {}) {
  return {
    sinceDate: url.searchParams.get("since_date"),
    untilDate: url.searchParams.get("until_date"),
    type: url.searchParams.get("type"),
    accountId: overrides.accountId ?? null,
    payeeId: overrides.payeeId ?? null,
    categoryId: overrides.categoryId ?? null,
    month: overrides.month ? normaliseMonthStart(overrides.month) : null,
    lastKnowledgeOfServer: parseNumber(url.searchParams.get("last_knowledge_of_server")) ?? null,
  };
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

async function handleAuth(request: Request, url: URL, store: AuthStore, config: ApiConfig): Promise<Response> {
  const path = url.pathname;
  const method = request.method.toUpperCase();

  if (path === "/api/auth/status" && method === "GET") {
    const principal = await authenticate(request, store, config.apiToken);
    const user = principal?.kind === "session"
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
    const user = await store.authenticateSession(sha256(token), Math.floor(Date.now() / 1_000));
    return user ? { kind: "session", transport: "bearer", ...user } : null;
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

function canRead(principal: Principal, planId: string, defaultPlanId: string): boolean {
  return principal.kind === "api-token"
    ? planId === defaultPlanId
    : Object.prototype.hasOwnProperty.call(principal.roles, planId);
}

function authorizePlan(principal: Principal, planId: string, defaultPlanId: string, method: string): Response | null {
  if (!canRead(principal, planId, defaultPlanId)) {
    return apiError(404, "resource_not_found", "Plan not found", "404.2");
  }
  if (principal.kind === "session" && isUnsafeMethod(method) && principal.roles[planId] === "viewer") {
    return apiError(403, "forbidden", "Plan is read-only");
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
