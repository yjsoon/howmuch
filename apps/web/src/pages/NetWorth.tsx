import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { SteppedArea } from "../components/charts";
import { formatDate, formatPeriod, trailingMonthsRange } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";

const TRAILING_YEAR = () => trailingMonthsRange(12);

export function NetWorthPage() {
  const { filters, setFilters, reportQuery } = useFilters({ defaultRange: TRAILING_YEAR });
  const query = { ...reportQuery, category_ids: undefined };
  const report = useApi(JSON.stringify(query), () => api.netWorth(query));

  const periods = report.data?.periods ?? [];
  const latest = periods[periods.length - 1];
  const previous = periods[periods.length - 2];
  const delta = latest && previous ? latest.net_worth - previous.net_worth : null;
  const trackedAccounts = latest?.accounts.length ?? 0;

  // Accounts that never move in this window (long-closed cards etc.) only add noise.
  const activeAccountIds = new Set(
    periods.flatMap((period) =>
      period.accounts.filter((account) => account.balance !== 0).map((account) => account.account_id),
    ),
  );
  const visibleAccounts = (period: (typeof periods)[number]) =>
    period.accounts.filter((account) => activeAccountIds.has(account.account_id));

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
              {latest ? formatMoney(latest.net_worth) : "-"}
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
          <div className="headline-figure">
            <span className="figure-label">Tracked accounts</span>
            <span className="figure-value">{trackedAccounts || "-"}</span>
          </div>
        </div>
      </div>

      {report.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load net worth history.</p>
          <p className="status-detail">{report.error}</p>
        </div>
      )}
      {report.loading && !report.data && (
        <div className="status-panel">
          <p className="status-title">Loading net worth history...</p>
        </div>
      )}

      {report.data && (
        <>
          {periods.length > 0 ? (
            <>
              <section className="report-section">
                <div className="section-heading">
                  <span className="section-title">Trend</span>
                  <span className="section-meta">{periods.length} closing snapshots</span>
                </div>
                <SteppedArea periods={periods} />
              </section>
              <section className="report-section">
                <div className="section-heading">
                  <span className="section-title">Account balances</span>
                  <span className="section-meta">Newest periods first</span>
                </div>
                <div className="table-wrap table-wrap-wide">
                  <table className="ledger-table">
                    <thead>
                      <tr>
                        <th>Period</th>
                        {latest &&
                          visibleAccounts(latest).map((account) => (
                            <th key={account.account_id} className="num">
                              {account.account_name}
                            </th>
                          ))}
                        <th className="num">Net worth</th>
                        <th className="num">Delta</th>
                      </tr>
                    </thead>
                    <tbody>
                      {[...periods].reverse().map((period, index, reversed) => {
                        const prior = reversed[index + 1];
                        const change = prior ? period.net_worth - prior.net_worth : null;
                        return (
                          <tr key={period.period}>
                            <td>{formatPeriod(period.period)}</td>
                            {visibleAccounts(period).map((account) => (
                              <td
                                key={account.account_id}
                                className={account.balance < 0 ? "num amount-negative" : "num"}
                              >
                                {formatMoney(account.balance)}
                              </td>
                            ))}
                            <td className="num strong">{formatMoney(period.net_worth)}</td>
                            <td
                              className={
                                change === null
                                  ? "num muted"
                                  : change >= 0
                                    ? "num amount-positive"
                                    : "num amount-negative"
                              }
                            >
                              {change === null ? "-" : formatMoney(change, { sign: true })}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </section>
            </>
          ) : (
            <div className="status-panel">
              <p className="status-title">No account history in this range.</p>
              <p className="status-detail">Widen the range or include more accounts to build a net worth series.</p>
            </div>
          )}
        </>
      )}
    </>
  );
}
