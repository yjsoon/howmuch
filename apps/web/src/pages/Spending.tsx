import { Fragment, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { isQuietGroupName } from "../lib/categories";
import { formatAmount, formatShare } from "../lib/money";
import { loadPrefs, savePrefs } from "../state/prefs";
import { transactionsLink, useFilters } from "../state/filters";

export function SpendingPage() {
  const { filters, setFilters, reportQuery } = useFilters();
  const query = { ...reportQuery, interval: undefined };
  const report = useApi(JSON.stringify(query), () => api.spendingBreakdown(query));

  const [includeQuiet, setIncludeQuiet] = useState(() => loadPrefs().includeQuietSpending ?? false);
  const toggleQuiet = () => {
    setIncludeQuiet((value) => {
      savePrefs({ includeQuietSpending: !value });
      return !value;
    });
  };

  // An explicit category filter is a deliberate choice — never hide its results.
  const hideQuiet = !includeQuiet && filters.categoryIds.length === 0;

  const { grouped, total, excluded, maxAmount } = useMemo(() => {
    if (!report.data) {
      return { grouped: [], total: 0, excluded: 0, maxAmount: 1 };
    }
    const rows = hideQuiet
      ? report.data.groups.filter((row) => !isQuietGroupName(row.category_group_name))
      : report.data.groups;
    const groups = new Map<string, { name: string; amount: number; rows: typeof rows }>();
    for (const row of rows) {
      const group = groups.get(row.category_group_id) ?? {
        name: row.category_group_name,
        amount: 0,
        rows: [],
      };
      group.amount += row.amount;
      group.rows.push(row);
      groups.set(row.category_group_id, group);
    }
    const total = rows.reduce((sum, row) => sum + row.amount, 0);
    return {
      grouped: [...groups.values()].sort((a, b) => b.amount - a.amount),
      total,
      excluded: report.data.total - total,
      // The API returns rows sorted by amount, so the first visible row is the widest bar.
      maxAmount: rows[0]?.amount ?? 1,
    };
  }, [report.data, hideQuiet]);

  return (
    <>
      <FilterRail filters={filters} setFilters={setFilters} busy={report.loading} />
      <div className="report-header">
        <h1>Spending breakdown</h1>
        <div className="headline-figure">
          <span className="figure-label">Total spending</span>
          <span className="figure-value figure-negative">{formatAmount(total)}</span>
        </div>
      </div>

      {report.error && <p className="error-note">{report.error}</p>}
      {report.loading && !report.data && <p className="loading-note">Loading…</p>}

      {report.data && (
        <>
          {filters.categoryIds.length === 0 && (excluded > 0 || includeQuiet) && (
            <p className="diagnostic-note">
              {includeQuiet
                ? "Including hidden & non-personal categories."
                : `${formatAmount(excluded)} in hidden & non-personal categories excluded.`}{" "}
              <button type="button" className="inline-link" onClick={toggleQuiet}>
                {includeQuiet ? "Exclude" : "Include"}
              </button>
            </p>
          )}
          <table className="ledger-table breakdown-table">
          <thead>
            <tr>
              <th>Category</th>
              <th className="col-bar" aria-hidden="true"></th>
              <th className="num">Amount</th>
              <th className="num">Share</th>
              <th className="num">Txns</th>
            </tr>
          </thead>
          <tbody>
            {grouped.map((group) => (
              <Fragment key={group.name}>
                <tr className="group-row">
                  <td>{group.name}</td>
                  <td className="col-bar"></td>
                  <td className="num">{formatAmount(group.amount)}</td>
                  <td className="num">{total > 0 ? formatShare(group.amount / total) : "—"}</td>
                  <td className="num"></td>
                </tr>
                {group.rows.map((row) => (
                  <tr key={row.category_id}>
                    <td className="indent">
                      <Link to={transactionsLink(filters, row.category_id)} className="drill-link">
                        {row.category_name}
                      </Link>
                    </td>
                    <td className="col-bar">
                      <span
                        className="share-bar"
                        style={{ width: `${(row.amount / maxAmount) * 100}%` }}
                      />
                    </td>
                    <td className="num">{formatAmount(row.amount)}</td>
                    <td className="num muted">{total > 0 ? formatShare(row.amount / total) : "—"}</td>
                    <td className="num muted">{row.transaction_count}</td>
                  </tr>
                ))}
              </Fragment>
            ))}
            {grouped.length === 0 && (
              <tr>
                <td colSpan={5} className="empty-row">
                  No spending in this range.
                </td>
              </tr>
            )}
          </tbody>
          </table>
        </>
      )}
    </>
  );
}
