import {
  boundaryWindow,
  foldNetWorthPeriods,
  monthOf,
} from "./account-month-balances";
import type { AsyncSqlDatabase } from "./async-sql";
import { assembleIncomeVsSpendingGroups } from "./income-vs-spending-groups";
import { buildRewardsReport } from "./rewards/build";
import { parseAppSettings, parseCreditCards, parseRewardGroupBy } from "./rewards/parse";
import { mapRewardTransactionRow } from "./rewards/rows";
import type { ReportFilters } from "./types";

type Row = Record<string, any>;

export class AsyncReportService {
  constructor(private readonly db: AsyncSqlDatabase) {}

  async spendingBreakdown(planId: string, filters: ReportFilters = {}): Promise<any> {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const rows = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         COALESCE(c.id, 'uncategorised') AS category_id,
         COALESCE(c.name, 'Uncategorised') AS category_name,
         COALESCE(cg.id, 'uncategorised-group') AS category_group_id,
         COALESCE(cg.name, 'Uncategorised') AS category_group_name,
         SUM(ABS(lines.amount_milli)) AS amount,
         COUNT(*) AS transaction_count
       FROM lines
       LEFT JOIN categories c ON c.id = lines.category_id
       LEFT JOIN category_groups cg ON cg.id = c.category_group_id
       WHERE ${where} AND lines.amount_milli < 0
       GROUP BY 1, 2, 3, 4
       ORDER BY amount DESC, category_group_id, category_id`,
      params,
    );
    const limit = bind(params, filters.topPayeesLimit ?? 5);
    const topPayeeRows = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         COALESCE(lines.payee_id, 'unknown-payee') AS payee_id,
         COALESCE(p.name, lines.payee_name_snapshot, 'Unknown') AS payee_name,
         SUM(ABS(lines.amount_milli)) AS amount
       FROM lines
       LEFT JOIN payees p ON p.id = lines.payee_id
       WHERE ${where} AND lines.amount_milli < 0
       GROUP BY 1, 2
       ORDER BY amount DESC, payee_id, payee_name
       LIMIT ${limit}`,
      params,
    );

    const total = rows.reduce((sum, row) => sum + Number(row.amount), 0);
    return {
      total,
      groups: rows.map((row) => ({
        category_id: row.category_id,
        category_name: row.category_name,
        category_group_id: row.category_group_id,
        category_group_name: row.category_group_name,
        amount: Number(row.amount),
        share: total > 0 ? Number(row.amount) / total : 0,
        transaction_count: Number(row.transaction_count),
      })),
      top_payees: topPayeeRows.map((row) => ({
        payee_id: row.payee_id === "unknown-payee" ? null : row.payee_id,
        payee_name: row.payee_name,
        amount: Number(row.amount),
        share: total > 0 ? Number(row.amount) / total : 0,
      })),
    };
  }

  async incomeVsSpending(planId: string, filters: ReportFilters = {}): Promise<any> {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const interval = filters.interval ?? "month";
    const rows = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         ${periodSql(interval)} AS period,
         SUM(CASE WHEN lines.amount_milli > 0 THEN lines.amount_milli ELSE 0 END) AS income,
         SUM(CASE WHEN lines.amount_milli < 0 THEN ABS(lines.amount_milli) ELSE 0 END) AS spending
       FROM lines
       WHERE ${where}
       GROUP BY period
       ORDER BY period`,
      params,
    );

    let cumulativeNet = 0;
    return {
      interval,
      periods: rows.map((row) => {
        const income = Number(row.income ?? 0);
        const spending = Number(row.spending ?? 0);
        const net = income - spending;
        cumulativeNet += net;
        return { period: row.period, income, spending, net, cumulative_net: cumulativeNet };
      }),
    };
  }

  /**
   * Per-window income/spending groups using the same line-item rules as
   * `incomeVsSpending`: sign-based, plain transfers out, categorised
   * transfers in, split lines as lines, no quiet-group exclusion.
   */
  async incomeVsSpendingGroups(planId: string, filters: ReportFilters = {}): Promise<any> {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const totals = await this.db.get<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         SUM(CASE WHEN lines.amount_milli > 0 THEN lines.amount_milli ELSE 0 END) AS income,
         SUM(CASE WHEN lines.amount_milli < 0 THEN ABS(lines.amount_milli) ELSE 0 END) AS spending
       FROM lines
       WHERE ${where}`,
      params,
    );
    const incomeByPayee = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         lines.payee_id AS payee_id,
         COALESCE(p.name, lines.payee_name_snapshot, 'No payee') AS payee_name,
         SUM(lines.amount_milli) AS amount,
         COUNT(*) AS transaction_count,
         COUNT(DISTINCT COALESCE(c.id, 'uncategorised')) AS category_count,
         MIN(COALESCE(c.id, 'uncategorised')) AS category_id,
         MIN(COALESCE(c.name, 'Uncategorised')) AS category_name
       FROM lines
       LEFT JOIN payees p ON p.id = lines.payee_id
       LEFT JOIN categories c ON c.id = lines.category_id
       WHERE ${where} AND lines.amount_milli > 0
       GROUP BY 1, 2`,
      params,
    );
    const incomeByCategory = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         COALESCE(c.id, 'uncategorised') AS category_id,
         COALESCE(c.name, 'Uncategorised') AS category_name,
         SUM(lines.amount_milli) AS amount,
         COUNT(*) AS transaction_count
       FROM lines
       LEFT JOIN categories c ON c.id = lines.category_id
       WHERE ${where} AND lines.amount_milli > 0
       GROUP BY 1, 2`,
      params,
    );
    const spendingByCategory = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT
         COALESCE(c.id, 'uncategorised') AS category_id,
         COALESCE(c.name, 'Uncategorised') AS category_name,
         COALESCE(cg.id, 'uncategorised-group') AS category_group_id,
         COALESCE(cg.name, 'Uncategorised') AS category_group_name,
         SUM(ABS(lines.amount_milli)) AS amount,
         COUNT(*) AS transaction_count
       FROM lines
       LEFT JOIN categories c ON c.id = lines.category_id
       LEFT JOIN category_groups cg ON cg.id = c.category_group_id
       WHERE ${where} AND lines.amount_milli < 0
       GROUP BY 1, 2, 3, 4`,
      params,
    );

    return assembleIncomeVsSpendingGroups({
      income: Number(totals?.income ?? 0),
      spending: Number(totals?.spending ?? 0),
      incomeByPayee,
      incomeByCategory,
      spendingByCategory,
    });
  }

  async netWorth(planId: string, filters: ReportFilters = {}): Promise<any> {
    const from = filters.from ?? (await earliestDate(this.db, planId)) ?? todayIso();
    const to = filters.to ?? todayIso();
    const periods = buildPeriods(from, to, filters.interval ?? "month");
    if (periods.length === 0) return { periods: [] };

    const requestedAccounts = filters.accountIds?.length ? new Set(filters.accountIds) : null;
    const accounts = (await this.db.all<Row>(
      `SELECT id,name,closed,opening_balance_milli FROM accounts
       WHERE plan_id=$1 AND deleted=0 AND include_in_net_worth=1
         AND ($2=1 OR closed=0)
       ORDER BY name,id`,
      [planId, filters.includeClosedAccounts === true ? 1 : 0],
    )).filter((account) => !requestedAccounts || requestedAccounts.has(account.id));

    // Whole months come from the aggregate, so the report reads months x
    // accounts instead of replaying the ledger.  The trigger-maintained table
    // is authoritative; see `account-month-balances.ts`.
    const monthly = await this.db.all<Row>(
      `SELECT account_id,month,net_change_milli FROM account_month_balances
       WHERE plan_id=$1 AND month<=$2`,
      [planId, monthOf(periods.at(-1)!.end)],
    );

    // Only period ends that fall mid-month need day-level detail, and then only
    // for the months they land in.  For monthly and yearly intervals that is at
    // most the trailing month; for daily and weekly intervals it is the
    // requested window, never the history before it.
    const window = boundaryWindow(periods);
    const boundary = window
      ? (await this.db.all<Row>(
          `SELECT account_id,date,amount_milli FROM transactions
           WHERE plan_id=$1 AND deleted=0 AND date>=$2 AND date<=$3`,
          [planId, window.from, window.to],
        )).filter((row) => window.months.includes(monthOf(String(row.date))))
      : [];

    return {
      periods: foldNetWorthPeriods(
        accounts.map((account) => ({
          id: String(account.id),
          name: String(account.name),
          closed: Number(account.closed) === 1,
          opening_balance_milli: Number(account.opening_balance_milli),
        })),
        periods,
        monthly.map((row) => ({
          account_id: String(row.account_id),
          month: String(row.month),
          net_change_milli: Number(row.net_change_milli),
        })),
        boundary.map((row) => ({
          account_id: String(row.account_id),
          date: String(row.date),
          amount_milli: Number(row.amount_milli),
        })),
      ),
    };
  }

  /**
   * Age of money replays every income lot over the whole ledger, so the result
   * is cached against the plan's `server_knowledge` rather than recomputed on
   * each call.  The cache is validated, not stale: the knowledge counter is
   * read *before* the ledger, and a hit is served only when it still matches,
   * so a write that lands mid-flight invalidates the entry it raced rather than
   * being papered over.  This satisfies the no-stale-cache constraint in #144.
   */
  async ageOfMoney(planId: string, filters: ReportFilters = {}): Promise<any> {
    // `categoryGroupIds` resolves through a join on `categories`, and category
    // upserts do not bump the plan's knowledge counter, so a cached answer for
    // that filter could outlive a category being moved between groups.  Every
    // other filter reads columns that live on the transaction lines
    // themselves.  Recompute rather than risk a stale answer (#144).
    const cacheable = !filters.categoryGroupIds?.length;
    const knowledge = cacheable ? await planKnowledge(this.db, planId) : null;
    const from = filters.from ?? (await earliestDate(this.db, planId)) ?? todayIso();
    const to = filters.to ?? todayIso();
    const key = reportCacheKey("age-of-money", { ...filters, from, to, interval: filters.interval ?? "month" });

    if (knowledge != null) {
      const cached = await this.db.get<Row>(
        "SELECT payload_json FROM report_cache WHERE plan_id = $1 AND cache_key = $2 AND server_knowledge = $3",
        [planId, key, knowledge],
      );
      if (cached) return JSON.parse(String(cached.payload_json));
    }

    const payload = await this.computeAgeOfMoney(planId, filters, from, to);
    if (knowledge != null) await this.storeReportCache(planId, key, knowledge, payload);
    return payload;
  }

  private async storeReportCache(planId: string, key: string, knowledge: number, payload: unknown): Promise<void> {
    // Best effort: a read-only transition deployment, or a database that has
    // not yet applied the aggregate migration, must still serve the report.
    try {
      await this.db.run("DELETE FROM report_cache WHERE plan_id = $1 AND server_knowledge < $2", [planId, knowledge]);
      await this.db.run(
        `INSERT INTO report_cache (plan_id, cache_key, server_knowledge, payload_json, computed_at)
         VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id, cache_key) DO UPDATE SET
           server_knowledge = excluded.server_knowledge,
           payload_json = excluded.payload_json,
           computed_at = CURRENT_TIMESTAMP
         WHERE excluded.server_knowledge >= report_cache.server_knowledge`,
        [planId, key, knowledge, JSON.stringify(payload)],
      );
    } catch {
      // Ignore: the cache is an optimisation, never a correctness requirement.
    }
  }

  private async computeAgeOfMoney(planId: string, filters: ReportFilters, from: string, to: string): Promise<any> {
    const { linesSql, where, params } = this.lineFilters(planId, filters, true);
    const rows = await this.db.all<Row>(
      `WITH lines AS (${linesSql})
       SELECT date, amount_milli FROM lines
       WHERE ${where}
       ORDER BY date ASC, ledger_sequence ASC, line_sequence ASC`,
      params,
    );

    const lots: Array<{ date: string; amount: number }> = [];
    const interval = filters.interval ?? "month";
    const buckets = new Map<string, { weightedAge: number; spent: number; unmatched: number }>(
      buildPeriods(from, to, interval).map((period) => [period.label, { weightedAge: 0, spent: 0, unmatched: 0 }]),
    );

    for (const row of rows) {
      const amount = Number(row.amount_milli);
      if (amount > 0) {
        lots.push({ date: row.date, amount });
        continue;
      }
      if (amount >= 0) continue;

      let remaining = Math.abs(amount);
      const period = periodLabel(row.date, interval);
      const bucket = buckets.get(period) ?? { weightedAge: 0, spent: 0, unmatched: 0 };
      while (remaining > 0 && lots.length > 0) {
        const lot = lots[0];
        const used = Math.min(remaining, lot.amount);
        bucket.weightedAge += daysBetween(lot.date, row.date) * used;
        bucket.spent += used;
        remaining -= used;
        lot.amount -= used;
        if (lot.amount === 0) lots.shift();
      }
      if (remaining > 0) bucket.unmatched += remaining;
      buckets.set(period, bucket);
    }

    return {
      interval,
      periods: [...buckets.entries()].map(([period, bucket]) => ({
        period,
        age_of_money_days: bucket.spent > 0 ? bucket.weightedAge / bucket.spent : null,
        spent: bucket.spent,
        unmatched_spending: bucket.unmatched,
      })),
    };
  }

  async rewards(planId: string, filters: ReportFilters = {}) {
    const snapshot = await this.db.get<{ payload_json: string }>(
      "SELECT payload_json FROM rewards_tracker_snapshots WHERE plan_id = $1",
      [planId],
    );
    const cardRows = await this.db.all<{ payload_json: string }>(
      "SELECT payload_json FROM rewards_tracker_cards WHERE plan_id = $1 AND deleted = 0 ORDER BY name, id",
      [planId],
    );
    const parsedSnapshot = snapshot ? JSON.parse(String(snapshot.payload_json)) as { settings?: unknown } : null;
    const cards = parseCreditCards(cardRows.map((row) => JSON.parse(String(row.payload_json))));
    const accountIds = cards.map((card) => card.ynabAccountId);
    const params: any[] = [];
    const clauses = [`t.plan_id = ${bind(params, planId)}`, "t.deleted = 0"];
    // Keep earlier period history for caps and minimum-spend qualification.
    if (filters.to) clauses.push(`t.date <= ${bind(params, filters.to)}`);
    const selectedAccounts = filters.accountIds?.length ? filters.accountIds : accountIds;
    if (selectedAccounts.length) appendInFilter(clauses, params, "t.account_id", selectedAccounts);
    else clauses.push("1 = 0");
    const rows = await this.db.all<Parameters<typeof mapRewardTransactionRow>[0]>(
      `SELECT t.id, t.date, t.amount_milli, t.account_id, a.name AS account_name,
         t.flag_color, t.flag_name, t.memo, t.transfer_account_id,
         COALESCE(p.name, t.payee_name_snapshot) AS payee_name,
         COALESCE(c.name, t.category_name_snapshot) AS category_name
       FROM transactions t
       JOIN accounts a ON a.id = t.account_id
       LEFT JOIN payees p ON p.id = t.payee_id
       LEFT JOIN categories c ON c.id = t.category_id
       WHERE ${clauses.join(" AND ")}
       ORDER BY t.date, t.id`,
      params,
    );
    const accountNames = Object.fromEntries(rows.map((row) => [String(row.account_id), String(row.account_name)]));
    for (const card of cards) {
      if (accountNames[card.ynabAccountId]) continue;
      const account = await this.db.get<{ name: string }>(
        "SELECT name FROM accounts WHERE plan_id = $1 AND id = $2",
        [planId, card.ynabAccountId],
      );
      if (account) accountNames[card.ynabAccountId] = account.name;
    }
    return buildRewardsReport({
      cards,
      accountNames,
      transactions: rows.map(mapRewardTransactionRow),
      settings: parseAppSettings(parsedSnapshot?.settings),
      from: filters.from ?? null,
      to: filters.to ?? null,
      range: filters.rewardsRange,
      groupBy: parseRewardGroupBy(filters.groupBy),
      accountIds: filters.accountIds ?? [],
    });
  }

  private lineFilters(planId: string, filters: ReportFilters, includeTransfers = false) {
    const params: any[] = [];
    const inner = [`t.plan_id = ${bind(params, planId)}`, "t.deleted = 0"];
    if (filters.from) inner.push(`t.date >= ${bind(params, filters.from)}`);
    if (filters.to) inner.push(`t.date <= ${bind(params, filters.to)}`);
    appendInFilter(inner, params, "t.account_id", filters.accountIds);
    const clauses: string[] = [];
    if (!includeTransfers && filters.includeTransfers !== true) {
      clauses.push("(lines.category_id IS NOT NULL OR (lines.transfer_transaction_id IS NULL AND lines.transfer_account_id IS NULL))");
    }
    appendCategoryFilter(clauses, params, filters.categoryIds);
    appendInFilter(clauses, params, "lines.category_group_id", filters.categoryGroupIds);
    appendInFilter(clauses, params, "lines.payee_id", filters.payeeIds);
    return { linesSql: lineItemsSql(inner.join(" AND ")), where: clauses.length ? clauses.join(" AND ") : "1=1", params };
  }
}

function lineItemsSql(innerWhere: string): string {
  return `
    SELECT t.id AS transaction_id, t.ledger_sequence, COALESCE(st.ledger_sequence, 0) AS line_sequence,
      t.plan_id, t.account_id, t.date,
      COALESCE(st.amount_milli, t.amount_milli) AS amount_milli,
      COALESCE(st.payee_id, t.payee_id) AS payee_id,
      COALESCE(st.payee_name_snapshot, t.payee_name_snapshot) AS payee_name_snapshot,
      COALESCE(st.category_id, t.category_id) AS category_id,
      c.category_group_id,
      COALESCE(st.transfer_transaction_id, t.transfer_transaction_id) AS transfer_transaction_id,
      COALESCE(st.transfer_account_id, t.transfer_account_id) AS transfer_account_id,
      t.deleted
    FROM transactions t
    LEFT JOIN subtransactions st ON st.transaction_id = t.id AND st.deleted = 0
    LEFT JOIN categories c ON c.id = COALESCE(st.category_id, t.category_id)
    WHERE (${innerWhere}) AND (
      NOT EXISTS (
        SELECT 1 FROM subtransactions existing WHERE existing.transaction_id = t.id AND existing.deleted = 0
      ) OR st.id IS NOT NULL
    )`;
}

const UNCATEGORISED_ID = "uncategorised";

function appendCategoryFilter(clauses: string[], params: any[], values?: string[]): void {
  if (!values?.length) return;
  const ids = values.filter((value) => value !== UNCATEGORISED_ID);
  if (ids.length === values.length) appendInFilter(clauses, params, "lines.category_id", ids);
  else if (!ids.length) clauses.push("lines.category_id IS NULL");
  else clauses.push(`(lines.category_id IN (${ids.map((id) => bind(params, id)).join(", ")}) OR lines.category_id IS NULL)`);
}

function appendInFilter(clauses: string[], params: any[], column: string, values?: string[]): void {
  if (!values?.length) return;
  clauses.push(`${column} IN (${values.map((value) => bind(params, value)).join(", ")})`);
}

function bind(params: any[], value: any): string {
  params.push(value);
  return `$${params.length}`;
}

function periodSql(interval: string): string {
  if (interval === "day") return "lines.date";
  if (interval === "year") return "substr(lines.date, 1, 4)";
  if (interval === "week") return "strftime('%Y-W%W', lines.date)";
  return "substr(lines.date, 1, 7)";
}

function periodLabel(date: string, interval: string): string {
  if (interval === "day") return date;
  if (interval === "year") return date.slice(0, 4);
  if (interval === "week") {
    const d = new Date(`${date}T00:00:00Z`);
    const start = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
    const week = Math.floor((Number(d) - Number(start)) / (7 * 86400000));
    return `${d.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
  }
  return date.slice(0, 7);
}

/** The plan's current `server_knowledge`, or null when the plan is unknown. */
async function planKnowledge(db: AsyncSqlDatabase, planId: string): Promise<number | null> {
  const row = await db.get<Row>("SELECT server_knowledge FROM plans WHERE id = $1", [planId]);
  if (!row || row.server_knowledge == null) return null;
  return Number(row.server_knowledge);
}

/**
 * A stable key for one report request.  Filter keys are sorted so that two
 * requests differing only in property order share a cache entry, and the
 * resolved `from`/`to` are part of the key because both default to today.
 */
function reportCacheKey(report: string, filters: Record<string, unknown>): string {
  const entries = Object.entries(filters)
    .filter(([, value]) => value !== undefined)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
  return `${report}:${JSON.stringify(entries)}`;
}

async function earliestDate(db: AsyncSqlDatabase, planId: string): Promise<string | null> {
  const row = await db.get<Row>("SELECT MIN(date) AS date FROM transactions WHERE plan_id = $1 AND deleted = 0", [planId]);
  return row?.date ?? null;
}

function buildPeriods(from: string, to: string, interval: string): Array<{ label: string; end: string }> {
  const periods: Array<{ label: string; end: string }> = [];
  const cursor = new Date(`${from}T00:00:00Z`);
  const end = new Date(`${to}T00:00:00Z`);
  while (cursor <= end) {
    const label = periodLabel(cursor.toISOString().slice(0, 10), interval);
    const periodEnd = new Date(cursor);
    if (interval === "year") periodEnd.setUTCMonth(11, 31);
    else if (interval === "week") periodEnd.setUTCDate(periodEnd.getUTCDate() + 6);
    else if (interval !== "day") periodEnd.setUTCMonth(periodEnd.getUTCMonth() + 1, 0);
    if (periodEnd > end) periodEnd.setTime(end.getTime());
    periods.push({ label, end: periodEnd.toISOString().slice(0, 10) });
    if (interval === "year") cursor.setUTCFullYear(cursor.getUTCFullYear() + 1, 0, 1);
    else if (interval === "week") cursor.setUTCDate(cursor.getUTCDate() + 7);
    else if (interval === "day") cursor.setUTCDate(cursor.getUTCDate() + 1);
    else cursor.setUTCMonth(cursor.getUTCMonth() + 1, 1);
  }
  return periods;
}

function daysBetween(from: string, to: string): number {
  return Math.max(0, Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000));
}

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}
