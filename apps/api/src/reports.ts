import type { Database } from "bun:sqlite";
import { assembleIncomeVsSpendingGroups } from "./income-vs-spending-groups";
import { buildRewardsReport } from "./rewards/build";
import { parseAppSettings, parseCreditCards, parseRewardGroupBy } from "./rewards/parse";
import { mapRewardTransactionRow } from "./rewards/rows";
import type { ReportFilters } from "./types";

type Row = Record<string, any>;

/**
 * The synchronous, full-history report implementation, used by the bun:sqlite
 * server.  `netWorth` and `ageOfMoney` here are the reference implementation
 * that `apps/api/tests/report-aggregates.test.ts` compares the aggregate-backed
 * D1 reports against: do not optimise them without first making that test
 * compute its expected values independently, or the parity check goes vacuous.
 */
export class ReportService {
  constructor(private readonly db: Database) {}

  spendingBreakdown(planId: string, filters: ReportFilters = {}): any {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const rows = this.db
      .query(
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
      )
      .all(...params) as Row[];
    const topPayeeRows = this.db
      .query(
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
         LIMIT ?`,
      )
      .all(...params, filters.topPayeesLimit ?? 5) as Row[];

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

  incomeVsSpending(planId: string, filters: ReportFilters = {}): any {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const interval = filters.interval ?? "month";
    const periodExpression = periodSql(interval);
    const rows = this.db
      .query(
        `WITH lines AS (${linesSql})
         SELECT
           ${periodExpression} AS period,
           SUM(CASE WHEN lines.amount_milli > 0 THEN lines.amount_milli ELSE 0 END) AS income,
           SUM(CASE WHEN lines.amount_milli < 0 THEN ABS(lines.amount_milli) ELSE 0 END) AS spending
         FROM lines
         WHERE ${where}
         GROUP BY period
         ORDER BY period`,
      )
      .all(...params) as Row[];

    let cumulativeNet = 0;
    return {
      interval,
      periods: rows.map((row) => {
        const income = Number(row.income ?? 0);
        const spending = Number(row.spending ?? 0);
        const net = income - spending;
        cumulativeNet += net;
        return {
          period: row.period,
          income,
          spending,
          net,
          cumulative_net: cumulativeNet,
        };
      }),
    };
  }

  /**
   * Per-window income/spending groups using the same line-item rules as
   * `incomeVsSpending`: sign-based, plain transfers out, categorised
   * transfers in, split lines as lines, no quiet-group exclusion.
   */
  incomeVsSpendingGroups(planId: string, filters: ReportFilters = {}): any {
    const { linesSql, where, params } = this.lineFilters(planId, filters);
    const totals = this.db
      .query(
        `WITH lines AS (${linesSql})
         SELECT
           SUM(CASE WHEN lines.amount_milli > 0 THEN lines.amount_milli ELSE 0 END) AS income,
           SUM(CASE WHEN lines.amount_milli < 0 THEN ABS(lines.amount_milli) ELSE 0 END) AS spending
         FROM lines
         WHERE ${where}`,
      )
      .get(...params) as Row;
    const incomeByPayee = this.db
      .query(
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
      )
      .all(...params) as Row[];
    const incomeByCategory = this.db
      .query(
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
      )
      .all(...params) as Row[];
    const spendingByCategory = this.db
      .query(
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
      )
      .all(...params) as Row[];

    return assembleIncomeVsSpendingGroups({
      income: Number(totals?.income ?? 0),
      spending: Number(totals?.spending ?? 0),
      incomeByPayee,
      incomeByCategory,
      spendingByCategory,
    });
  }

  netWorth(planId: string, filters: ReportFilters = {}): any {
    const from = filters.from ?? earliestDate(this.db, planId) ?? todayIso();
    const to = filters.to ?? todayIso();
    const periods = buildPeriods(from, to, filters.interval ?? "month");
    const accounts = this.db
      .query(
        `SELECT * FROM accounts
         WHERE plan_id = ?
           AND deleted = 0
           AND include_in_net_worth = 1
           AND (? = 1 OR closed = 0)
         ORDER BY name, id`,
      )
      .all(planId, filters.includeClosedAccounts === true ? 1 : 0) as Row[];

    let previousNetWorth: number | null = null;
    const rows = periods.map((period) => {
      const accountRows = accounts
        .filter((account) => !filters.accountIds?.length || filters.accountIds.includes(account.id))
        .map((account) => {
          const balanceRow = this.db
            .query(
              `SELECT ? + COALESCE(SUM(CASE WHEN deleted = 0 THEN amount_milli ELSE 0 END), 0) AS balance
               FROM transactions
               WHERE plan_id = ? AND account_id = ? AND date <= ?`,
            )
            .get(Number(account.opening_balance_milli ?? 0), planId, account.id, period.end) as Row;
          return {
            account_id: account.id,
            account_name: account.name,
            closed: account.closed === 1,
            balance: Number(balanceRow.balance ?? 0),
          };
        });
      const netWorth = accountRows.reduce((sum, account) => sum + account.balance, 0);
      const delta = previousNetWorth == null ? null : netWorth - previousNetWorth;
      previousNetWorth = netWorth;
      return {
        period: period.label,
        end_date: period.end,
        net_worth: netWorth,
        delta,
        accounts: accountRows,
      };
    });

    return { periods: rows };
  }

  ageOfMoney(planId: string, filters: ReportFilters = {}): any {
    const from = filters.from ?? earliestDate(this.db, planId) ?? todayIso();
    const to = filters.to ?? todayIso();
    const { linesSql, where, params } = this.lineFilters(planId, filters, true);
    const rows = this.db
      .query(
        `WITH lines AS (${linesSql})
         SELECT date, amount_milli
         FROM lines
         WHERE ${where}
         ORDER BY date ASC, ledger_sequence ASC, line_sequence ASC`,
      )
      .all(...params) as Row[];

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
      if (amount >= 0) {
        continue;
      }

      let remaining = Math.abs(amount);
      const period = periodLabel(row.date, interval);
      const bucket = buckets.get(period) ?? { weightedAge: 0, spent: 0, unmatched: 0 };

      while (remaining > 0 && lots.length > 0) {
        const lot = lots[0];
        const used = Math.min(remaining, lot.amount);
        const age = daysBetween(lot.date, row.date);
        bucket.weightedAge += age * used;
        bucket.spent += used;
        remaining -= used;
        lot.amount -= used;
        if (lot.amount === 0) {
          lots.shift();
        }
      }

      if (remaining > 0) {
        bucket.unmatched += remaining;
      }
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

  rewards(planId: string, filters: ReportFilters = {}) {
    const snapshot = this.db
      .query("SELECT payload_json FROM rewards_tracker_snapshots WHERE plan_id = ?")
      .get(planId) as { payload_json: string } | null;
    const cardRows = this.db
      .query("SELECT payload_json FROM rewards_tracker_cards WHERE plan_id = ? AND deleted = 0 ORDER BY name, id")
      .all(planId) as Array<{ payload_json: string }>;
    const parsedSnapshot = snapshot ? JSON.parse(String(snapshot.payload_json)) as { settings?: unknown } : null;
    const cards = parseCreditCards(cardRows.map((row) => JSON.parse(String(row.payload_json))));
    const accountIds = cards.map((card) => card.ynabAccountId);
    const clauses = ["t.plan_id = ?", "t.deleted = 0"];
    const params: any[] = [planId];
    // Keep earlier period history for caps and minimum-spend qualification.
    if (filters.to) {
      clauses.push("t.date <= ?");
      params.push(filters.to);
    }
    const selectedAccounts = filters.accountIds?.length ? filters.accountIds : accountIds;
    if (selectedAccounts.length) {
      clauses.push(`t.account_id IN (${selectedAccounts.map(() => "?").join(", ")})`);
      params.push(...selectedAccounts);
    } else {
      clauses.push("1 = 0");
    }
    const rows = this.db
      .query(
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
      )
      .all(...params) as Array<Parameters<typeof mapRewardTransactionRow>[0]>;
    const accountNames = Object.fromEntries(rows.map((row) => [String(row.account_id), String(row.account_name)]));
    for (const card of cards) {
      if (!accountNames[card.ynabAccountId]) {
        const account = this.db
          .query("SELECT name FROM accounts WHERE plan_id = ? AND id = ?")
          .get(planId, card.ynabAccountId) as { name: string } | null;
        if (account) accountNames[card.ynabAccountId] = account.name;
      }
    }
    return buildRewardsReport({
      cards,
      accountNames,
      transactions: rows.map(mapRewardTransactionRow),
      settings: parseAppSettings(parsedSnapshot?.settings),
      from: filters.from ?? null,
      to: filters.to ?? null,
      groupBy: parseRewardGroupBy(filters.groupBy),
      accountIds: filters.accountIds ?? [],
    });
  }

  private lineFilters(planId: string, filters: ReportFilters, includeTransfers = false): { linesSql: string; where: string; params: any[] } {
    const inner = ["t.plan_id = ?", "t.deleted = 0"];
    const params: any[] = [planId];

    if (filters.from) {
      inner.push("t.date >= ?");
      params.push(filters.from);
    }
    if (filters.to) {
      inner.push("t.date <= ?");
      params.push(filters.to);
    }
    appendInFilter(inner, params, "t.account_id", filters.accountIds);

    const clauses: string[] = [];
    if (!includeTransfers && filters.includeTransfers !== true) {
      // YNAB counts categorised transfers (e.g. paying a tracking-account
      // loan) as spending; only uncategorised transfer legs stay out.
      clauses.push(
        "(lines.category_id IS NOT NULL OR (lines.transfer_transaction_id IS NULL AND lines.transfer_account_id IS NULL))",
      );
    }
    appendCategoryFilter(clauses, params, filters.categoryIds);
    appendInFilter(clauses, params, "lines.category_group_id", filters.categoryGroupIds);
    appendInFilter(clauses, params, "lines.payee_id", filters.payeeIds);

    return { linesSql: lineItemsSql(inner.join(" AND ")), where: clauses.length ? clauses.join(" AND ") : "1=1", params };
  }
}

function lineItemsSql(innerWhere: string): string {
  return `
    SELECT
      t.id AS transaction_id,
      t.rowid AS ledger_sequence,
      COALESCE(st.rowid, 0) AS line_sequence,
      t.plan_id,
      t.account_id,
      t.date,
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
        SELECT 1 FROM subtransactions existing
        WHERE existing.transaction_id = t.id AND existing.deleted = 0
      )
      OR st.id IS NOT NULL
    )
  `;
}

/** Spending breakdown surfaces uncategorised lines under this synthetic id. */
const UNCATEGORISED_ID = "uncategorised";

/** Category filter that treats the synthetic uncategorised id as `category_id IS NULL`. */
function appendCategoryFilter(clauses: string[], params: any[], values?: string[]): void {
  if (!values?.length) {
    return;
  }
  const ids = values.filter((value) => value !== UNCATEGORISED_ID);
  if (ids.length === values.length) {
    appendInFilter(clauses, params, "lines.category_id", ids);
  } else if (!ids.length) {
    clauses.push("lines.category_id IS NULL");
  } else {
    clauses.push(`(lines.category_id IN (${ids.map(() => "?").join(", ")}) OR lines.category_id IS NULL)`);
    params.push(...ids);
  }
}

function appendInFilter(clauses: string[], params: any[], column: string, values?: string[]): void {
  if (!values?.length) {
    return;
  }
  clauses.push(`${column} IN (${values.map(() => "?").join(", ")})`);
  params.push(...values);
}

function periodSql(interval: string): string {
  if (interval === "day") {
    return "lines.date";
  }
  if (interval === "year") {
    return "substr(lines.date, 1, 4)";
  }
  if (interval === "week") {
    return "strftime('%Y-W%W', lines.date)";
  }
  return "substr(lines.date, 1, 7)";
}

function periodLabel(date: string, interval: string): string {
  if (interval === "day") {
    return date;
  }
  if (interval === "year") {
    return date.slice(0, 4);
  }
  if (interval === "week") {
    const d = new Date(`${date}T00:00:00Z`);
    const start = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
    const week = Math.floor((Number(d) - Number(start)) / (7 * 86400000));
    return `${d.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
  }
  return date.slice(0, 7);
}

function earliestDate(db: Database, planId: string): string | null {
  const row = db.query("SELECT MIN(date) AS date FROM transactions WHERE plan_id = ? AND deleted = 0").get(planId) as Row;
  return row.date ?? null;
}

function buildPeriods(from: string, to: string, interval: string): Array<{ label: string; end: string }> {
  const periods: Array<{ label: string; end: string }> = [];
  const cursor = new Date(`${from}T00:00:00Z`);
  const end = new Date(`${to}T00:00:00Z`);

  while (cursor <= end) {
    const label = periodLabel(cursor.toISOString().slice(0, 10), interval);
    const periodEnd = new Date(cursor);
    if (interval === "year") {
      periodEnd.setUTCMonth(11, 31);
    } else if (interval === "week") {
      periodEnd.setUTCDate(periodEnd.getUTCDate() + 6);
    } else if (interval === "day") {
      // already the day end for date-based comparison
    } else {
      periodEnd.setUTCMonth(periodEnd.getUTCMonth() + 1, 0);
    }
    if (periodEnd > end) {
      periodEnd.setTime(end.getTime());
    }
    periods.push({ label, end: periodEnd.toISOString().slice(0, 10) });

    if (interval === "year") {
      cursor.setUTCFullYear(cursor.getUTCFullYear() + 1, 0, 1);
    } else if (interval === "week") {
      cursor.setUTCDate(cursor.getUTCDate() + 7);
    } else if (interval === "day") {
      cursor.setUTCDate(cursor.getUTCDate() + 1);
    } else {
      cursor.setUTCMonth(cursor.getUTCMonth() + 1, 1);
    }
  }

  return periods;
}

function daysBetween(from: string, to: string): number {
  return Math.max(0, Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000));
}

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}
