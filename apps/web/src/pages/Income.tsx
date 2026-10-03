import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { PairedColumns } from "../components/charts";
import { formatPeriod, ytdRange } from "../lib/dates";
import { formatAmount, formatMoney, formatSavingsRate } from "../lib/money";
import { useFilters } from "../state/filters";

export function IncomePage() {
  const { filters, setFilters, reportQuery } = useFilters({ defaultRange: ytdRange });
  const report = useApi(JSON.stringify(reportQuery), () => api.incomeVsSpending(reportQuery));

  const periods = report.data?.periods ?? [];
  const totals = periods.reduce(
    (sums, period) => ({
      income: sums.income + period.income,
      spending: sums.spending + period.spending,
    }),
    { income: 0, spending: 0 },
  );
  const net = totals.income - totals.spending;
  const savingsRate = formatSavingsRate(net, totals.income);

  return (
    <>
      <FilterRail
        filters={filters}
        setFilters={setFilters}
        intervals={["week", "month", "year"]}
        busy={report.loading}
      />
      <div className="report-header">
        <h1>Income v spending</h1>
        <div className="headline-row">
          <div className="headline-figure">
            <span className="figure-label">Income</span>
            <span className="figure-value figure-positive">{formatAmount(totals.income)}</span>
          </div>
          <div className="headline-figure">
            <span className="figure-label">Spending</span>
            <span className="figure-value figure-negative">{formatAmount(totals.spending)}</span>
          </div>
          <div className="headline-figure">
            <span className="figure-label">Net</span>
            <span className={net >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {formatMoney(net, { sign: true })}
            </span>
          </div>
          <div className="headline-figure">
            <span className="figure-label">Savings rate</span>
            {/* An em dash means "no meaningful rate", so it stays neutral
                rather than being coloured by a sign it does not show. */}
            <span
              className={
                savingsRate === "—"
                  ? "figure-value"
                  : net >= 0
                    ? "figure-value figure-positive"
                    : "figure-value figure-negative"
              }
            >
              {savingsRate}
            </span>
          </div>
        </div>
      </div>

      {report.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load the income report.</p>
          <p className="status-detail">{report.error}</p>
        </div>
      )}
      {report.loading && !report.data && (
        <div className="status-panel">
          <p className="status-title">Loading income versus spending…</p>
        </div>
      )}

      {report.data && (
        <>
          {periods.length > 0 ? (
            <>
              <section className="report-section">
                <div className="section-heading">
                  <span className="section-title">Trend</span>
                  <span className="section-meta">{periods.length} periods in view</span>
                </div>
                <PairedColumns periods={periods} />
              </section>
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
                        <th className="num">Income</th>
                        <th className="num">Spending</th>
                        <th className="num">Net</th>
                        <th className="num">Cumulative net</th>
                      </tr>
                    </thead>
                    <tbody>
                      {[...periods].reverse().map((period) => (
                        <tr key={period.period}>
                          <td>{formatPeriod(period.period)}</td>
                          <td className="num amount-positive">{formatAmount(period.income)}</td>
                          <td className="num amount-negative">{formatAmount(period.spending)}</td>
                          <td className={period.net >= 0 ? "num amount-positive" : "num amount-negative"}>
                            {formatMoney(period.net, { sign: true })}
                          </td>
                          <td className="num muted">{formatMoney(period.cumulative_net, { sign: true })}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
            </>
          ) : (
            <div className="status-panel">
              <p className="status-title">No activity in this range.</p>
              <p className="status-detail">Try widening the date range or clearing account filters.</p>
            </div>
          )}
        </>
      )}
    </>
  );
}
