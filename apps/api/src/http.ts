import type { Database } from "bun:sqlite";
import type { ApiConfig } from "./config";
import { LedgerRepository, NotFoundError } from "./repository";
import { ReportService } from "./reports";
import { decimalToMilliunits } from "./money";
import { importCsvRows } from "./importers/csv";
import { importYnabFromApi } from "./importers/ynab";

type HandlerOptions = {
  db: Database;
  config: ApiConfig;
};

export function createHandler({ db, config }: HandlerOptions): (request: Request) => Promise<Response> {
  const repo = new LedgerRepository(db, config.defaultPlanId);
  const reports = new ReportService(db);
  repo.ensurePlan(config.defaultPlanId);

  return async function handle(request: Request): Promise<Response> {
    try {
      if (!isAuthorised(request, config.apiToken)) {
        return json({ error: { id: "unauthorised", message: "Invalid bearer token" } }, 401);
      }

      const url = new URL(request.url);
      const segments = url.pathname.split("/").filter(Boolean);

      if (url.pathname === "/health") {
        return json({ ok: true });
      }

      if (segments[0] === "v1") {
        return await handleV1(request, url, segments, repo);
      }

      if (segments[0] === "api") {
        return await handleNative(request, url, segments, repo, reports);
      }

      return json({ error: { id: "not_found", message: "Route not found" } }, 404);
    } catch (error) {
      if (error instanceof NotFoundError) {
        return json({ error: { id: "not_found", message: error.message } }, 404);
      }
      return json(
        {
          error: {
            id: "internal_error",
            message: error instanceof Error ? error.message : String(error),
          },
        },
        500,
      );
    }
  };
}

async function handleV1(request: Request, url: URL, segments: string[], repo: LedgerRepository): Promise<Response> {
  const method = request.method.toUpperCase();

  if (segments.length === 2 && segments[1] === "user" && method === "GET") {
    return json({ data: { user: { id: "local-user" } } });
  }

  const collection = segments[1];
  if (collection !== "plans" && collection !== "budgets") {
    return json({ error: { id: "not_found", message: "Route not found" } }, 404);
  }

  const isBudgetAlias = collection === "budgets";
  if (segments.length === 2 && method === "GET") {
    const plans = repo.listPlans();
    return json({ data: isBudgetAlias ? { budgets: plans } : { plans } });
  }

  const planId = segments[2];
  repo.ensurePlan(planId);

  if (segments.length === 3 && method === "GET") {
    const plan = repo.getPlan(planId);
    return json({ data: isBudgetAlias ? { budget: plan } : { plan } });
  }

  const resource = segments[3];

  if (resource === "settings" && segments.length === 4 && method === "GET") {
    return json({ data: { settings: repo.getSettings(planId) } });
  }

  if (resource === "accounts") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: { accounts: repo.listAccounts(planId), server_knowledge: repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      repo.upsertAccount(planId, body.account ?? body);
      return json({ data: { account: repo.getAccount(planId, (body.account ?? body).id), server_knowledge: repo.getServerKnowledge(planId) } }, 201);
    }
    const accountId = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { account: repo.getAccount(planId, accountId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: repo.listTransactions(planId, queryFilters(url, { accountId })),
          server_knowledge: repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "categories" && segments.length === 4 && method === "GET") {
    return json({ data: { category_groups: repo.listCategoryGroups(planId), server_knowledge: repo.getServerKnowledge(planId) } });
  }
  if (resource === "categories") {
    const categoryId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: repo.listTransactions(planId, queryFilters(url, { categoryId })),
          server_knowledge: repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "payees") {
    if (segments.length === 4 && method === "GET") {
      return json({ data: { payees: repo.listPayees(planId), server_knowledge: repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      const payee = repo.createPayee(planId, body.payee?.name ?? body.name);
      return json({ data: { payee, server_knowledge: repo.getServerKnowledge(planId) } }, 201);
    }
    const payeeId = segments[4];
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: repo.listTransactions(planId, queryFilters(url, { payeeId })),
          server_knowledge: repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "months") {
    const month = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { month: repo.getMonth(planId, month), server_knowledge: repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 6 && segments[5] === "transactions" && method === "GET") {
      return json({
        data: {
          transactions: repo.listTransactions(planId, queryFilters(url, { month })),
          server_knowledge: repo.getServerKnowledge(planId),
        },
      });
    }
  }

  if (resource === "transactions") {
    if (segments.length === 4 && method === "GET") {
      return json({
        data: {
          transactions: repo.listTransactions(planId, queryFilters(url)),
          server_knowledge: repo.getServerKnowledge(planId),
        },
      });
    }
    if (segments.length === 4 && method === "POST") {
      const body = await readJson(request);
      const created = repo.createTransaction(planId, body.transaction);
      return json({ data: { transaction: created, transaction_ids: [created.id], server_knowledge: repo.getServerKnowledge(planId) } }, 201);
    }
    if (segments.length === 5 && segments[4] === "import" && method === "POST") {
      const body = await readJson(request);
      const result = repo.importTransactions(
        planId,
        (body.transactions ?? []).map((transaction: any) => transaction.transaction ?? transaction),
      );
      return json({ data: result }, 201);
    }

    const transactionId = segments[4];
    if (segments.length === 5 && method === "GET") {
      return json({ data: { transaction: repo.getTransaction(planId, transactionId), server_knowledge: repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && (method === "PUT" || method === "PATCH")) {
      const body = await readJson(request);
      const updated = repo.updateTransaction(planId, transactionId, body.transaction ?? body);
      return json({ data: { transaction: updated, server_knowledge: repo.getServerKnowledge(planId) } });
    }
    if (segments.length === 5 && method === "DELETE") {
      const deleted = repo.deleteTransaction(planId, transactionId);
      return json({ data: { transaction: deleted, server_knowledge: repo.getServerKnowledge(planId) } });
    }
  }

  return json({ error: { id: "not_found", message: "Route not found" } }, 404);
}

async function handleNative(
  request: Request,
  url: URL,
  segments: string[],
  repo: LedgerRepository,
  reports: ReportService,
): Promise<Response> {
  const method = request.method.toUpperCase();
  const planId = url.searchParams.get("plan_id") ?? repo.getDefaultPlanId();
  repo.ensurePlan(planId);

  if (segments[1] === "reports" && method === "GET") {
    const filters = reportFilters(url);
    if (segments[2] === "spending-breakdown") {
      return json({ data: reports.spendingBreakdown(planId, filters) });
    }
    if (segments[2] === "income-vs-spending") {
      return json({ data: reports.incomeVsSpending(planId, filters) });
    }
    if (segments[2] === "net-worth") {
      return json({ data: reports.netWorth(planId, filters) });
    }
    if (segments[2] === "age-of-money") {
      return json({ data: reports.ageOfMoney(planId, filters) });
    }
  }

  if (segments[1] === "mobile" && segments[2] === "quick-entry" && method === "POST") {
    const body = await readJson(request);
    const amount = body.amount_milli ?? decimalToMilliunits(body.amount);
    const transaction = repo.createTransaction(planId, {
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
    });
    return json({ data: { transaction, server_knowledge: repo.getServerKnowledge(planId) } }, 201);
  }

  if (segments[1] === "import" && segments[2] === "csv" && method === "POST") {
    const body = await readJson(request);
    const result = importCsvRows(repo, body.plan_id ?? planId, body.account_id, body.rows ?? []);
    return json({ data: result }, 201);
  }

  if (segments[1] === "import" && segments[2] === "ynab" && method === "POST") {
    const body = await readJson(request);
    const result = await importYnabFromApi(repo, {
      token: body.token,
      planId: body.plan_id ?? planId,
      baseUrl: body.base_url,
      sinceDate: body.since_date,
    });
    return json({ data: result }, 201);
  }

  return json({ error: { id: "not_found", message: "Route not found" } }, 404);
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
  return text ? JSON.parse(text) : {};
}

function isAuthorised(request: Request, token?: string): boolean {
  if (!token) {
    return true;
  }
  return request.headers.get("authorization") === `Bearer ${token}`;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}
