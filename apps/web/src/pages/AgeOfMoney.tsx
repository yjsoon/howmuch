import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { DottedLine } from "../components/charts";
import { formatPeriod } from "../lib/dates";
import { formatAmount } from "../lib/money";
import { useFilters } from "../state/filters";

// Age of money replays income lots from the start of the range, so a clipped
// window distorts the figure — default to the full history.
const ALL_TIME = () => ({});

export function AgeOfMoneyPage() {
  const { filters, setFilters, reportQuery } = useFilters({ defaultRange: ALL_TIME });
  const query = { ...reportQuery, category_ids: undefined };
  const report = useApi(JSON.stringify(query), () => api.ageOfMoney(query));

  const periods = report.data?.periods ?? [];
  const latest = [...periods].reverse().find((period) => period.age_of_money_days !== null);
  const unmatchedTotal = periods.reduce((sum, period) => sum + period.unmatched_spending, 0);

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
        <h1>Age of money</h1>
        <div className="headline-row">
          <div className="headline-figure">
            <span className="figure-label">
              {latest ? `Latest (${formatPeriod(latest.period)})` : "Latest"}
            </span>
            <span className="figure-value">
              {latest?.age_of_money_days != null ? `${Math.round(latest.age_of_money_days)} days` : "—"}
            </span>
          </div>
        </div>
      </div>

      {report.error && <p className="error-note">{report.error}</p>}
      {report.loading && !report.data && <p className="loading-note">Loading…</p>}

      {report.data && (
        <>
          <DottedLine
            periods={periods.map((period) => ({
              period: period.period,
              value: period.age_of_money_days,
            }))}
          />
          {unmatchedTotal > 0 && (
            <p className="diagnostic-note">
              {formatAmount(unmatchedTotal)} of spending predates the earliest recorded income and is
              excluded from the weighted age.
            </p>
          )}
          <table className="ledger-table">
            <thead>
              <tr>
                <th>Period</th>
                <th className="num">Age of money</th>
                <th className="num">Spending matched</th>
                <th className="num">Unmatched spending</th>
              </tr>
            </thead>
            <tbody>
              {[...periods].reverse().map((period) => (
                <tr key={period.period}>
                  <td>{formatPeriod(period.period)}</td>
                  <td className="num strong">
                    {period.age_of_money_days != null ? `${Math.round(period.age_of_money_days)} days` : "—"}
                  </td>
                  <td className="num">{formatAmount(period.spent)}</td>
                  <td className="num muted">
                    {period.unmatched_spending > 0 ? formatAmount(period.unmatched_spending) : "—"}
                  </td>
                </tr>
              ))}
              {periods.length === 0 && (
                <tr>
                  <td colSpan={4} className="empty-row">
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
