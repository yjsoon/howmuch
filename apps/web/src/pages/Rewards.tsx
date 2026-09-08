import { useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { RewardsReport } from "../api/types";
import { FlagTag } from "../components/FlagTag";
import { FilterRail } from "../components/FilterRail";
import { formatAmount } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

const ALL_TIME = () => ({});
const GROUPS = ["flag", "payee", "category", "memo"] as const;

function dollars(value: number): string {
  return formatAmount(Math.round(value * 1000));
}

export function RewardsPage() {
  const { planId } = usePlan();
  const location = useLocation();
  const { filters, setFilters, reportQuery } = useFilters({ defaultRange: ALL_TIME });
  const query = { ...reportQuery, category_ids: undefined, interval: undefined };
  const [refresh, setRefresh] = useState(0);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [milesText, setMilesText] = useState<string | null>(null);
  const report = useApi(`${JSON.stringify(query)}:${refresh}`, () => api.rewards(query));
  const storedCards = report.data?.cards ?? [];
  const visibleCards = storedCards.filter((row) => !row.calculation.maximum_spend_exceeded);
  const cashback = visibleCards.filter((row) => row.card.type === "cashback");
  const miles = visibleCards.filter((row) => row.card.type === "miles");
  const emptyImported = report.data && storedCards.length === 0;
  const addCardHref = { pathname: "/rewards/new", search: location.search };
  const milesValue = milesText ?? (report.data ? String(report.data.miles_valuation) : "");

  const saveMilesValuation = async () => {
    const trimmed = milesText?.trim() ?? "";
    if (!trimmed || !report.data) return;
    const milesValuation = Number(trimmed);
    if (!Number.isFinite(milesValuation)) {
      setSettingsError("Miles valuation must be a number.");
      return;
    }
    if (milesValuation === report.data.miles_valuation) return;
    setSettingsError(null);
    try {
      await api.updateRewardSettings(planId, { milesValuation });
      setMilesText(String(milesValuation));
      setRefresh((value) => value + 1);
    } catch (cause) {
      setSettingsError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  return (
    <>
      <FilterRail
        filters={filters}
        setFilters={setFilters}
        showCategories={false}
        groups={[...GROUPS]}
        busy={report.loading}
      />
      <div className="report-header">
        <h1>Rewards</h1>
        <div className="headline-row">
          <div className="headline-figure">
            <span className="figure-label">Qualifying spend</span>
            <span className="figure-value">{dollars(report.data?.totals.spend ?? 0)}</span>
          </div>
          <div className="headline-figure">
            <span className="figure-label">Value</span>
            <span className="figure-value figure-positive">{dollars(report.data?.totals.reward_dollars ?? 0)}</span>
          </div>
          {(report.data?.totals.miles ?? 0) > 0 && (
            <div className="headline-figure">
              <span className="figure-label">Miles</span>
              <span className="figure-value">{Math.round(report.data?.totals.miles ?? 0).toLocaleString("en-GB")}</span>
            </div>
          )}
          {(report.data?.totals.cashback ?? 0) > 0 && (
            <div className="headline-figure">
              <span className="figure-label">Cashback</span>
              <span className="figure-value figure-positive">{dollars(report.data?.totals.cashback ?? 0)}</span>
            </div>
          )}
          <label className="field rewards-miles-field">
            <span className="field-label">Miles valuation</span>
            <input
              type="text"
              inputMode="decimal"
              value={milesValue}
              onChange={(event) => setMilesText(event.target.value)}
              onBlur={() => void saveMilesValuation()}
              aria-label="Miles valuation"
            />
            <span className="field-note">Currency units assigned to each mile.</span>
          </label>
          <Link to={addCardHref} className="register-add-link">Add card</Link>
        </div>
      </div>

      {report.error && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not load rewards.</p>
          <p className="status-detail">{report.error}</p>
        </div>
      )}

      {settingsError && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not update miles valuation.</p>
          <p className="status-detail">{settingsError}</p>
        </div>
      )}

      {report.loading && !report.data && (
        <div className="status-panel">
          <p className="status-title">Loading rewards…</p>
        </div>
      )}

      {emptyImported && (
        <div className="status-panel">
          <p className="status-title">No reward cards in this range.</p>
          <p className="status-detail">
            Import a Rewards Tracker export from <Link to="/import/rewards">Settings → Rewards import</Link>,
            or choose <Link to={addCardHref}>Add card</Link>.
          </p>
        </div>
      )}

      {storedCards.length > 0 && (
        <div className="rewards-board">
          {cashback.length > 0 && (
            <section className="rewards-type-group" aria-labelledby="rewards-cashback-heading">
              <h2 id="rewards-cashback-heading">Cashback</h2>
              <div className="rewards-card-grid">
                {cashback.map((row) => <RewardTile key={row.card.id} row={row} search={location.search} />)}
              </div>
            </section>
          )}
          {miles.length > 0 && (
            <section className="rewards-type-group" aria-labelledby="rewards-miles-heading">
              <h2 id="rewards-miles-heading">Miles</h2>
              <div className="rewards-card-grid">
                {miles.map((row) => <RewardTile key={row.card.id} row={row} search={location.search} />)}
              </div>
            </section>
          )}
        </div>
      )}

      {(report.data?.groups.length ?? 0) > 0 && (
        <section className="report-section" aria-labelledby="rewards-groups-heading">
          <div className="section-heading">
            <span className="section-title" id="rewards-groups-heading">
              By {filters.groupBy}
            </span>
            <span className="section-meta">{report.data?.groups.length} groups</span>
          </div>
          <table className="report-table">
            <thead>
              <tr>
                <th>Group</th>
                <th className="num">Spend</th>
                <th className="num">Reward</th>
                <th className="num">Txns</th>
              </tr>
            </thead>
            <tbody>
              {report.data?.groups.map((row) => (
                <tr key={row.key}>
                  <td>
                    <span className="rewards-group-label">
                      <FlagTag colour={row.flag_color} name={row.label} />
                      {row.flag_color ? null : row.label}
                    </span>
                  </td>
                  <td className="num">{dollars(row.spend)}</td>
                  <td className="num">{dollars(row.reward_dollars)}</td>
                  <td className="num">{row.transaction_count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}

function RewardTile({ row, search }: { row: RewardsReport["cards"][number]; search: string }) {
  const calc = row.calculation;
  const min = calc.minimum_spend;
  const progress = calc.minimum_spend_progress ?? 0;
  return (
    <Link to={{ pathname: `/rewards/${row.card.id}`, search }} className={calc.maximum_spend_exceeded ? "rewards-tile rewards-tile-capped" : "rewards-tile"}>
      <header className="rewards-tile-header">
        <div>
          <h3>{row.card.name}</h3>
          <p>{[row.card.issuer, row.account_name].filter(Boolean).join(" · ")}</p>
        </div>
        <span className={row.card.type === "miles" ? "rewards-chip rewards-chip-miles" : "rewards-chip"}>
          {formatReward(calc.reward_earned, calc.reward_type)}
        </span>
      </header>
      <dl className="rewards-tile-stats">
        <div>
          <dt>Spend</dt>
          <dd>{dollars(calc.total_spend)}</dd>
        </div>
        <div>
          <dt>Eligible</dt>
          <dd>{dollars(calc.eligible_spend)}</dd>
        </div>
        <div>
          <dt>Value</dt>
          <dd>{dollars(calc.reward_earned_dollars)}</dd>
        </div>
      </dl>
      {min != null && min > 0 && (
        <div className="rewards-progress">
          <div className="rewards-progress-label">
            <span>{calc.minimum_spend_met ? "Minimum met" : "Minimum spend"}</span>
            <span>{dollars(calc.total_spend)} / {dollars(min)}</span>
          </div>
          <div className="rewards-progress-track" role="progressbar" aria-valuenow={Math.round(progress)} aria-valuemin={0} aria-valuemax={100} aria-label="Minimum spend progress">
            <span style={{ width: `${Math.min(100, progress)}%` }} />
          </div>
        </div>
      )}
      {calc.flags.length > 0 && (
        <ul className="rewards-flag-list">
          {calc.flags.map((flag) => (
            <li key={flag.subcategoryId}>
              <FlagTag colour={flag.flagColor} name={flag.name} />
              <span>{flag.rewardRate ? `${flag.rewardRate}×` : ""}</span>
              <span className="num">{formatReward(flag.rewardEarned, calc.reward_type)}</span>
            </li>
          ))}
        </ul>
      )}
    </Link>
  );
}

function formatReward(amount: number, type: "cashback" | "miles" | undefined): string {
  if (type === "miles") return `${Math.round(amount).toLocaleString("en-GB")} mi`;
  return dollars(amount);
}
