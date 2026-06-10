import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { SteppedArea } from "../components/charts";
import { formatDate, formatPeriod } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";

export function NetWorthPage() {
  const { filters, setFilters, reportQuery } = useFilters();
  const query = { ...reportQuery, category_ids: undefined };
  const report = useApi(JSON.stringify(query), () => api.netWorth(query));

  const periods = report.data?.periods ?? [];
  const latest = periods[periods.length - 1];
  const previous = periods[periods.length - 2];
  const delta = latest && previous ? latest.net_worth - previous.net_worth : null;

  return (
    <>
      <FilterRail
        filters={filters}
        setFilters={setFilters}
        intervals={["week", "month"]}
        showCategories={false}
        busy={report.loading}
      />
      <div className="report-header">
        <h1>Net worth</h1>
        <div className="headline-row">
          <div className="headline-figure">
            <span className="figure-label">{latest ? `As at ${formatDate(latest.end_date)}` : "Current"}</span>
            <span className={!latest || latest.net_worth >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {latest ? formatMoney(latest.net_worth) : "—"}
            </span>
          </div>
          {delta !== null && (
            <div className="headline-figure">
              <span className="figure-label">Change on previous period</span>
              <span className={delta >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
                {formatMoney(delta, { sign: true })}
              </span>
            </div>
          )}
        </div>
      </div>

      {report.error && <p className="error-note">{report.error}</p>}
      {report.loading && !report.data && <p className="loading-note">Loading…</p>}

      {report.data && (
        <>
          <SteppedArea periods={periods} />
          <div className="table-scroll">
          <table className="ledger-table">
            <thead>
              <tr>
                <th>Period</th>
                {latest?.accounts.map((account) => (
                  <th key={account.account_id} className="num">
                    {account.account_name}
                  </th>
                ))}
                <th className="num">Net worth</th>
                <th className="num">Δ</th>
              </tr>
            </thead>
            <tbody>
              {[...periods].reverse().map((period, index, reversed) => {
                const prior = reversed[index + 1];
                const change = prior ? period.net_worth - prior.net_worth : null;
                return (
                  <tr key={period.period}>
                    <td>{formatPeriod(period.period)}</td>
                    {period.accounts.map((account) => (
                      <td
                        key={account.account_id}
                        className={account.balance < 0 ? "num amount-negative" : "num"}
                      >
                        {formatMoney(account.balance)}
                      </td>
                    ))}
                    <td className="num strong">{formatMoney(period.net_worth)}</td>
                    <td className={change === null ? "num muted" : change >= 0 ? "num amount-positive" : "num amount-negative"}>
                      {change === null ? "—" : formatMoney(change, { sign: true })}
                    </td>
                  </tr>
                );
              })}
              {periods.length === 0 && (
                <tr>
                  <td colSpan={3} className="empty-row">
                    No account history in this range.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          </div>
        </>
      )}
    </>
  );
}
