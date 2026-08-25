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
  const measuredPeriods = [...periods].filter((period) => period.age_of_money_days !== null);
  const latest = measuredPeriods[measuredPeriods.length - 1];
  const previous = measuredPeriods[measuredPeriods.length - 2];
  const delta =
    latest && previous ? Math.round(latest.age_of_money_days! - previous.age_of_money_days!) : null;
  const unmatchedTotal = periods.reduce((sum, period) => sum + period.unmatched_spending, 0);
  const matchedTotal = periods.reduce((sum, period) => sum + period.spent, 0);

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
          <div className="headline-figure">
            <span className="figure-label">Change on previous period</span>
            <span className={delta === null || delta >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {delta === null ? "—" : `${delta > 0 ? "+" : ""}${delta} days`}
            </span>
          </div>
          <div className="headline-figure">
            <span className="figure-label">Spending matched</span>
            <span className="figure-value">{matchedTotal > 0 ? formatAmount(matchedTotal) : "—"}</span>
          </div>
        </div>
      </div>

      {report.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load the age-of-money report.</p>
          <p className="status-detail">{report.error}</p>
        </div>
      )}
      {report.loading && !report.data && (
        <div className="status-panel">
          <p className="status-title">Loading age of money…</p>
        </div>
      )}

      {report.data && (
        <>
          {periods.length > 0 ? (
            <>
              <section className="report-section">
                <div className="section-heading">
                  <span className="section-title">Trend</span>
                  <span className="section-meta">{measuredPeriods.length} measured periods</span>
                </div>
                <DottedLine
                  periods={periods.map((period) => ({
                    period: period.period,
                    value: period.age_of_money_days,
                  }))}
                />
              </section>
              {unmatchedTotal > 0 && (
                <p className="diagnostic-note">
                  {formatAmount(unmatchedTotal)} of spending predates the earliest recorded income and is
                  excluded from the weighted age.
                </p>
              )}
              <section className="report-section">
                <div className="section-heading">
                  <span className="section-title">History</span>
                  <span className="section-meta">Newest periods first</span>
                </div>
                <div className="table-wrap">
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
                    </tbody>
                  </table>
                </div>
              </section>
            </>
          ) : (
            <div className="status-panel">
              <p className="status-title">No spending in this range.</p>
              <p className="status-detail">Need both income and spending before age of money can be calculated.</p>
            </div>
          )}
        </>
      )}
    </>
  );
}
