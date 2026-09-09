import { useEffect, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { CreditCard, RewardsReport } from "../api/types";
import { FlagTag } from "../components/FlagTag";
import { isFlagColour } from "../lib/flags";
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
  return <RewardsBoard key={planId} planId={planId} />;
}

type BoardPreferences = {
  featured: boolean;
  showHidden: boolean;
  hidden: string[];
  hiddenUntil: Record<string, string>;
  order: "manual" | "name" | "value" | "spend";
  cardOrder: string[];
  grouped: boolean;
  collapsedGroups: string[];
};
const DEFAULT_BOARD: BoardPreferences = { featured: false, showHidden: false, hidden: [], hiddenUntil: {}, order: "name", cardOrder: [], grouped: true, collapsedGroups: [] };

function loadBoard(planId: string): BoardPreferences {
  try {
    const value = JSON.parse(localStorage.getItem(`howmuch:rewards:${planId}`) ?? "null");
    if (!value || typeof value !== "object") return DEFAULT_BOARD;
    return { featured: value.featured === true, showHidden: value.showHidden === true,
      hidden: Array.isArray(value.hidden) ? value.hidden.filter((id: unknown) => typeof id === "string") : [],
      hiddenUntil: value.hiddenUntil && typeof value.hiddenUntil === "object" && !Array.isArray(value.hiddenUntil)
        ? Object.fromEntries(Object.entries(value.hiddenUntil).filter((entry): entry is [string, string] =>
          typeof entry[1] === "string" && /^\d{4}-\d{2}-\d{2}$/.test(entry[1]))) : {},
      order: value.order === "manual" || value.order === "value" || value.order === "spend" ? value.order : "name",
      cardOrder: Array.isArray(value.cardOrder) ? value.cardOrder.filter((id: unknown) => typeof id === "string") : [],
      grouped: value.grouped !== false,
      collapsedGroups: Array.isArray(value.collapsedGroups) ? value.collapsedGroups.filter((name: unknown) => name === "Cashback" || name === "Miles") : [],
    };
  } catch { return DEFAULT_BOARD; }
}

function RewardsBoard({ planId }: { planId: string }) {
  const location = useLocation();
  const { accounts } = usePlan();
  const { filters, setFilters, reportQuery } = useFilters({ defaultRange: ALL_TIME });
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Singapore", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  const query = { ...reportQuery, to: !filters.from && filters.to && filters.to > today ? today : reportQuery.to, category_ids: undefined, interval: undefined };
  useEffect(() => {
    if (!filters.from && filters.to && filters.to > today) setFilters({ to: today });
  }, [filters.from, filters.to, today, setFilters]);
  const [preferences, setPreferences] = useState(() => loadBoard(planId));
  const [selected, setSelected] = useState<string[]>([]);
  const [batchField, setBatchField] = useState<"featured" | "type" | "earningRate">("featured");
  const [batchValue, setBatchValue] = useState("true");
  const [batchBusy, setBatchBusy] = useState(false);
  const updatePreferences = (patch: Partial<BoardPreferences>) => {
    const next = { ...preferences, ...patch };
    setPreferences(next);
    try { localStorage.setItem(`howmuch:rewards:${planId}`, JSON.stringify(next)); } catch { /* Session-only when storage is unavailable. */ }
  };
  const [refresh, setRefresh] = useState(0);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [milesText, setMilesText] = useState<string | null>(null);
  const report = useApi(`${JSON.stringify(query)}:${refresh}`, () => api.rewards(query));
  const storedCards = report.data?.cards ?? [];
  // Keep IDs outside the current account/featured/hidden filters so moving a
  // visible card cannot discard another card's saved position.
  const cardOrder = [...new Set([...preferences.cardOrder, ...[...storedCards]
    .sort((a, b) => a.card.name.localeCompare(b.card.name)).map((row) => row.card.id)])];
  const positions = new Map(cardOrder.map((id, index) => [id, index]));
  const isHidden = (id: string) => preferences.hidden.includes(id) || (preferences.hiddenUntil[id] ?? "") > today;
  const visibleCards = storedCards.filter((row) => (!preferences.featured || row.card.featured)
    && (preferences.showHidden || !isHidden(row.card.id)))
    .sort((a, b) => preferences.order === "manual" ? positions.get(a.card.id)! - positions.get(b.card.id)!
      : preferences.order === "value" ? b.calculation.reward_earned_dollars - a.calculation.reward_earned_dollars
      : preferences.order === "spend" ? b.calculation.total_spend - a.calculation.total_spend : a.card.name.localeCompare(b.card.name));
  const groups = preferences.grouped ? [
    { name: "Cashback", rows: visibleCards.filter((row) => row.card.type === "cashback") },
    { name: "Miles", rows: visibleCards.filter((row) => row.card.type === "miles") },
  ] : [{ name: "Cards", rows: visibleCards }];
  const emptyImported = report.data && storedCards.length === 0;
  const addCardHref = { pathname: "/rewards/new", search: location.search };
  const milesValue = milesText ?? (report.data ? String(report.data.miles_valuation) : "");
  const moveCard = (id: string, neighborId: string) => {
    const next = [...cardOrder];
    const index = next.indexOf(id);
    const neighbor = next.indexOf(neighborId);
    [next[index], next[neighbor]] = [next[neighbor]!, next[index]!];
    updatePreferences({ cardOrder: next });
  };
  const toggleHidden = (id: string) => {
    if (!isHidden(id)) {
      updatePreferences({ hidden: [...preferences.hidden, id] });
      return;
    }
    const hiddenUntil = { ...preferences.hiddenUntil };
    delete hiddenUntil[id];
    updatePreferences({ hidden: preferences.hidden.filter((entry) => entry !== id), hiddenUntil });
  };

  const saveMilesValuation = async () => {
    const trimmed = milesText?.trim() ?? "";
    if (!trimmed || !report.data) return;
    const milesValuation = Number(trimmed);
    if (!Number.isFinite(milesValuation) || milesValuation < 0) {
      setSettingsError("Miles valuation must be a nonnegative number.");
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

  const applyBatch = async () => {
    const patch: Partial<CreditCard> = batchField === "featured" ? { featured: batchValue === "true" }
      : batchField === "type" ? { type: batchValue === "miles" ? "miles" : "cashback" } : { earningRate: Number(batchValue) };
    if (batchField === "earningRate" && (!batchValue.trim() || !Number.isFinite(patch.earningRate) || patch.earningRate! < 0)) {
      setSettingsError("Batch rate must be a nonnegative number."); return;
    }
    setBatchBusy(true); setSettingsError(null);
    const remaining = [...selected];
    try {
      for (const id of selected) {
        await api.updateRewardCard(planId, id, patch);
        remaining.splice(remaining.indexOf(id), 1);
      }
    } catch (cause) {
      setSettingsError(`${selected.length - remaining.length} cards updated. ${cause instanceof Error ? cause.message : String(cause)}`);
    } finally {
      setSelected(remaining); setBatchBusy(false); setRefresh((value) => value + 1);
    }
  };
  const requestedAsOf = query.to ?? report.data?.as_of ?? today;
  const asOf = requestedAsOf > today ? today : requestedAsOf;
  const shiftAsOf = (days: number) => {
    const date = new Date(`${asOf}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + days);
    const next = date.toISOString().slice(0, 10);
    if (next <= today) setFilters({ from: undefined, to: next });
  };

  return (
    <>
      <section className="rewards-controls" aria-label="Rewards board controls">
        <label className="field"><span className="field-label">Period mode</span>
          <select value={filters.from ? "range" : "current"} onChange={(event) => setFilters(event.target.value === "current"
            ? { from: undefined, to: undefined } : { from: `${asOf.slice(0, 7)}-01`, to: asOf })}>
            <option value="current">Card periods as of date</option><option value="range">Historical range</option>
          </select>
        </label>
        {!filters.from && <>
          <button type="button" onClick={() => shiftAsOf(-1)}>Previous day</button>
          <label className="field"><span className="field-label">As of</span><input type="date" value={asOf} max={today}
            onChange={(event) => event.target.value && setFilters({ from: undefined, to: event.target.value > today ? today : event.target.value })} /></label>
          <button type="button" disabled={asOf >= today} onClick={() => shiftAsOf(1)}>Next day</button>
          <button type="button" onClick={() => setFilters({ from: undefined, to: undefined })}>Today</button>
          <label className="field"><span className="field-label">Accounts</span>
            <select value={filters.accountIds.length === 1 ? filters.accountIds[0] : filters.accountIds.length ? "selected" : "all"}
              onChange={(event) => setFilters({ accountIds: event.target.value === "all" ? [] : [event.target.value] })}>
              <option value="all">All accounts</option>
              {filters.accountIds.length > 1 && <option value="selected">{filters.accountIds.length} selected accounts</option>}
              {accounts.map((account) => <option key={account.id} value={account.id}>{account.name}</option>)}
            </select>
          </label>
          <label className="field"><span className="field-label">Report grouping</span><select value={filters.groupBy}
            onChange={(event) => setFilters({ groupBy: event.target.value as typeof filters.groupBy })}>
            {GROUPS.map((group) => <option key={group} value={group}>{group}</option>)}
          </select></label>
        </>}
        <label className="field"><span className="field-label">Cards</span><select value={preferences.featured ? "featured" : "all"}
          onChange={(event) => updatePreferences({ featured: event.target.value === "featured" })}>
          <option value="all">All cards</option><option value="featured">Featured cards</option></select></label>
        <label className="field"><span className="field-label">Order</span><select value={preferences.order}
          onChange={(event) => updatePreferences({ order: event.target.value as BoardPreferences["order"] })}>
          <option value="manual">Manual</option><option value="name">Name</option><option value="value">Reward value</option><option value="spend">Spend</option></select></label>
        <label><input type="checkbox" checked={preferences.grouped} onChange={(event) => updatePreferences({ grouped: event.target.checked })} /> Group by type</label>
        <label><input type="checkbox" checked={preferences.showHidden} onChange={(event) => updatePreferences({ showHidden: event.target.checked })} /> Show hidden ({storedCards.filter((row) => isHidden(row.card.id)).length})</label>
      </section>
      <p className="field-note">{filters.from ? "Rewards attributed to the selected dates; qualification shows the latest card period." : "Each card uses its own billing or reward period. Today uses the server’s Singapore date."} Capped cards stay visible until you hide them.</p>
      {filters.from &&
      <FilterRail
        filters={filters}
        setFilters={setFilters}
        showCategories={false}
        groups={[...GROUPS]}
        busy={report.loading}
      />
      }
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
          <p className="status-title">Could not update rewards settings.</p>
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
            or choose <Link to={addCardHref}>Add card</Link> to score one of your HowMuch cards.
          </p>
        </div>
      )}

      {storedCards.length > 0 && (
        <div className="rewards-board">
          <div className="rewards-controls" aria-label="Batch card edits">
            <span>{selected.length} selected</span>
            <button type="button" disabled={batchBusy} onClick={() => setSelected(groups
              .filter((group) => !preferences.grouped || !preferences.collapsedGroups.includes(group.name))
              .flatMap((group) => group.rows.map((row) => row.card.id)))}>Select visible</button>
            <button type="button" disabled={batchBusy} onClick={() => setSelected([])}>Clear selection</button>
            <select aria-label="Batch field" value={batchField} disabled={batchBusy} onChange={(event) => {
              const field = event.target.value as typeof batchField; setBatchField(field); setBatchValue(field === "featured" ? "true" : field === "type" ? "cashback" : "");
            }}><option value="featured">Featured</option><option value="type">Type</option><option value="earningRate">Base earning rate</option></select>
            {batchField === "earningRate" ? <input aria-label="Batch value" inputMode="decimal" value={batchValue} onChange={(event) => setBatchValue(event.target.value)} />
              : <select aria-label="Batch value" value={batchValue} onChange={(event) => setBatchValue(event.target.value)}>
                {batchField === "featured" ? <><option value="true">Featured</option><option value="false">Not featured</option></> : <><option value="cashback">Cashback</option><option value="miles">Miles</option></>}
              </select>}
            <button type="button" disabled={!selected.length || batchBusy} onClick={() => void applyBatch()}>{batchBusy ? "Applying…" : "Apply to selected"}</button>
          </div>
          {!visibleCards.length && <p role="status">No cards match these preferences. Choose All cards or Show hidden.</p>}
          {groups.filter((group) => group.rows.length > 0).map((group) => (
            <section key={group.name} className="rewards-type-group" aria-label={group.name}>
              <h2>{preferences.grouped ? <button type="button" className="text-button"
                aria-expanded={!preferences.collapsedGroups.includes(group.name)} aria-controls={`rewards-group-${group.name}`}
                onClick={() => updatePreferences({ collapsedGroups: preferences.collapsedGroups.includes(group.name)
                  ? preferences.collapsedGroups.filter((name) => name !== group.name) : [...preferences.collapsedGroups, group.name] })}>
                {preferences.collapsedGroups.includes(group.name) ? "Expand" : "Collapse"} {group.name} ({group.rows.length})
              </button> : group.name}</h2>
              <div id={`rewards-group-${group.name}`} className="rewards-card-grid"
                style={preferences.grouped && preferences.collapsedGroups.includes(group.name) ? { display: "none" } : undefined}>
                {group.rows.map((row, index) => {
                  const expiry = nextCardPeriodDate(row);
                  return <div key={row.card.id} className="rewards-card-wrap">
                  <RewardTile row={row} search={location.search} asOf={report.data?.as_of} />
                  <div className="rewards-card-actions">
                    <label><input type="checkbox" disabled={batchBusy} checked={selected.includes(row.card.id)}
                      onChange={(event) => setSelected(event.target.checked ? [...selected, row.card.id] : selected.filter((id) => id !== row.card.id))} /> Select {row.card.name}</label>
                    <button type="button" className="text-button" onClick={() => toggleHidden(row.card.id)}>{isHidden(row.card.id) ? "Unhide" : "Hide"}</button>
                  </div>
                  {!preferences.hidden.includes(row.card.id) && (preferences.hiddenUntil[row.card.id] ?? "") > today &&
                    <p className="field-note">Hidden until {preferences.hiddenUntil[row.card.id]} (Singapore)</p>}
                  {!isHidden(row.card.id) && <div className="rewards-controls">
                    <button type="button" aria-label={`Hide ${row.card.name} until next period`}
                      disabled={!expiry || expiry <= today}
                      title={expiry && expiry > today ? `Returns ${expiry} (Singapore)` : "No upcoming period boundary in this report"}
                      onClick={() => expiry && updatePreferences({ hiddenUntil: { ...preferences.hiddenUntil, [row.card.id]: expiry } })}>Hide until next period</button>
                  </div>}
                  {preferences.order === "manual" && <div className="rewards-controls" aria-label={`Order ${row.card.name}`}>
                    <button type="button" aria-label={`Move ${row.card.name} up`} disabled={index === 0}
                      onClick={() => moveCard(row.card.id, group.rows[index - 1]!.card.id)}>Move up</button>
                    <button type="button" aria-label={`Move ${row.card.name} down`} disabled={index === group.rows.length - 1}
                      onClick={() => moveCard(row.card.id, group.rows[index + 1]!.card.id)}>Move down</button>
                  </div>}
                </div>;
                })}
              </div>
            </section>
          ))}
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

function nextCardPeriodDate(row: RewardsReport["cards"][number]): string | undefined {
  const end = row.calculation.periods?.reduce((latest, period) => period.end > latest ? period.end : latest, "");
  if (!end) return undefined;
  const date = new Date(`${end}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

export function RewardTile({ row, search, asOf }: { row: RewardsReport["cards"][number]; search: string; asOf?: string }) {
  const calc = row.calculation;
  // Historical amounts are range-attributed, while qualification belongs to the
  // cutoff period. An earlier promotion may sort after that calendar period.
  const fullPeriod = calc.periods?.filter((period) => asOf && period.start <= asOf && period.end >= asOf).at(-1)?.calculation;
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
      <p className="rewards-period">Period: {calc.periods?.map((period) => `${period.start} – ${period.end}`).join("; ") || calc.period}</p>
      {calc.maximum_spend_exceeded && <p className="rewards-cap-status">Cap reached</p>}
      {calc.should_stop_using && <p className="rewards-cap-status">Consider another card</p>}
      {calc.qualification_status && <p>Monthly qualification: {calc.qualification_status.replaceAll("_", " ")}</p>}
      {calc.monthly_qualifications && calc.monthly_qualifications.length > 0 && <ul className="rewards-months">
        {calc.monthly_qualifications.map((month) => <li key={month.start}>{month.start} – {month.end}: {dollars(month.spend)} / {dollars(month.minimumSpend)} · {month.status}</li>)}
      </ul>}
      {calc.active_spending_tier_id != null && <p>Active tier: {calc.active_spending_tier_id}</p>}
      {calc.has_next_spending_tier && calc.next_spending_tier_threshold != null && <p>Next tier at {dollars(calc.next_spending_tier_threshold)}</p>}
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
            <span>{fullPeriod ? (calc.minimum_spend_met ? "Full-period minimum met" : "Full-period minimum") : (calc.minimum_spend_met ? "Minimum met" : "Minimum spend")}</span>
            <span>{dollars(fullPeriod?.total_spend ?? calc.total_spend)} / {dollars(min)}</span>
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
              {isFlagColour(flag.flagColor)
                ? <FlagTag colour={flag.flagColor} name={flag.name} />
                : <span>{flag.name}</span>}
              <span>{flag.rewardRate != null ? `${flag.rewardRate}${calc.reward_type === "cashback" ? "%" : " miles/unit"}` : ""}</span>
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
