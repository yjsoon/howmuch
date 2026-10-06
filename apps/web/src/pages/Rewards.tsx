import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import { Link, useLocation } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { CreditCard, RewardsReport } from "../api/types";
import { FlagTag } from "../components/FlagTag";
import { isFlagColour } from "../lib/flags";
import { FilterRail } from "../components/FilterRail";
import { MultiSelect } from "../components/MultiSelect";
import { formatDate, formatDateRange } from "../lib/dates";
import { formatAmount } from "../lib/money";
import { useDismiss } from "../lib/use-dismiss";
import { withViewTransition } from "../lib/view-transition";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";
import "./rewards-board.css";

const ALL_TIME = () => ({});
const GROUPS = ["flag", "payee", "category", "memo"] as const;
const GROUP_LABEL: Record<(typeof GROUPS)[number], string> = { flag: "Flag", payee: "Payee", category: "Category", memo: "Memo" };

type Row = RewardsReport["cards"][number];
type Tone = "needs" | "earning" | "complete" | "failed" | "neutral";

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
const ORDERS: ReadonlyArray<BoardPreferences["order"]> = ["manual", "name", "value", "spend"];
const ORDER_LABEL: Record<BoardPreferences["order"], string> = { manual: "Manual", name: "Name", value: "Reward value", spend: "Spend" };

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
  const [selecting, setSelecting] = useState(false);
  // Cards a batch apply just wrote: each pulses once, then the list clears.
  const [justUpdated, setJustUpdated] = useState<string[]>([]);
  // Functional, so a patch queued behind a running board transition merges into
  // the latest preferences rather than the ones captured at its render.
  const updatePreferences = (patch: Partial<BoardPreferences>) => {
    setPreferences((prev) => {
      const next = { ...prev, ...patch };
      try { localStorage.setItem(`howmuch:rewards:${planId}`, JSON.stringify(next)); } catch { /* Session-only when storage is unavailable. */ }
      return next;
    });
  };
  const arrange = (patch: Partial<BoardPreferences>) => withViewTransition("board", () => updatePreferences(patch));
  const [refresh, setRefresh] = useState(0);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [milesText, setMilesText] = useState<string | null>(null);
  const report = useApi(`${JSON.stringify(query)}:${refresh}`, () => api.rewards(query));
  // Stale-while-revalidate, local to this page: a day step, valuation save or
  // batch apply keeps the last good report on screen (dimmed) until the next
  // one lands, instead of unmounting the board. An error still clears it.
  const lastGood = useRef<RewardsReport | null>(null);
  if (report.data) lastGood.current = report.data;
  const shown = report.error ? null : (report.data ?? lastGood.current);
  const refreshing = report.loading && shown != null;
  const storedCards = shown?.cards ?? [];
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
  const emptyImported = shown && storedCards.length === 0 && filters.accountIds.length === 0;
  const emptyForAccounts = shown && storedCards.length === 0 && filters.accountIds.length > 0;
  const addCardHref = { pathname: "/rewards/new", search: location.search };
  const milesValue = milesText ?? (shown ? String(shown.miles_valuation) : "");
  const hiddenCount = storedCards.filter((row) => isHidden(row.card.id)).length;
  const featuredCount = storedCards.filter((row) => row.card.featured).length;
  const range = Boolean(filters.from);
  const scopeLabel = filters.accountIds.length === 0 ? "All accounts"
    : filters.accountIds.length === 1 ? (accounts.find((account) => account.id === filters.accountIds[0])?.name ?? "1 account")
    : `${filters.accountIds.length} accounts`;
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
    if (!trimmed || !shown) return;
    const milesValuation = Number(trimmed);
    if (!Number.isFinite(milesValuation) || milesValuation < 0) {
      setSettingsError("Miles valuation must be a nonnegative number.");
      return;
    }
    if (milesValuation === shown.miles_valuation) return;
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
      setJustUpdated(selected.filter((id) => !remaining.includes(id)));
    }
  };
  useEffect(() => {
    if (!justUpdated.length) return;
    const timer = window.setTimeout(() => setJustUpdated([]), 900);
    return () => window.clearTimeout(timer);
  }, [justUpdated]);
  const requestedAsOf = query.to ?? report.data?.as_of ?? today;
  const asOf = requestedAsOf > today ? today : requestedAsOf;
  const shiftAsOf = (days: number) => {
    const date = new Date(`${asOf}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + days);
    const next = date.toISOString().slice(0, 10);
    if (next <= today) setFilters({ from: undefined, to: next });
  };
  const selectVisible = () => setSelected(groups
    .filter((group) => !preferences.grouped || !preferences.collapsedGroups.includes(group.name))
    .flatMap((group) => group.rows.map((row) => row.card.id)));

  return (
    <div className="rw-page" data-selecting={selecting || undefined}>
      <header className="rw-hero">
        <div className="rw-hero-text">
          <h1>Rewards</h1>
          <p className="rw-hero-scope">{range ? formatDateRange(filters.from, filters.to) : `Card periods as of ${formatDate(asOf)}`} · {scopeLabel}</p>
          {storedCards.length > 0 && (
            <p className="rw-hero-status">Showing {visibleCards.length} of {storedCards.length} cards · totals include hidden and non-featured cards</p>
          )}
          {/* R2: replace with RewardsBoardSummary, e.g. "2 below minimum · 1 capped" (data-tone spans) */}
        </div>
        <div className="rw-hero-figures">
          <Figure primary label="Value earned" value={dollars(shown?.totals.reward_dollars ?? 0)} />
          <Figure label="Qualifying spend" value={dollars(shown?.totals.spend ?? 0)} />
          {(shown?.totals.miles ?? 0) > 0 && <Figure label="Miles" value={Math.round(shown!.totals.miles).toLocaleString("en-GB")} />}
          {(shown?.totals.cashback ?? 0) > 0 && <Figure label="Cashback" value={dollars(shown!.totals.cashback)} />}
        </div>
        {shown && (
          <label className="rw-valuation">Miles valued at
            <input
              type="text"
              inputMode="decimal"
              value={milesValue}
              aria-label="Miles valuation"
              aria-describedby="rw-valuation-note"
              onChange={(event) => setMilesText(event.target.value)}
              onBlur={() => void saveMilesValuation()}
              onKeyDown={(event) => {
                if (event.key === "Enter") event.currentTarget.blur();
                if (event.key === "Escape") setMilesText(null);
              }}
            />
            each
            <span id="rw-valuation-note" className="sr-only">Currency units assigned to each mile.</span>
          </label>
        )}
        <Link to={addCardHref} className="add-button rw-add">Add card</Link>
      </header>

      <section className="rw-toolbar" aria-label="Rewards board controls">
        <div className="segmented" role="group" aria-label="Period mode">
          <button type="button" aria-pressed={!range} className={!range ? "segment segment-active" : "segment"}
            onClick={() => setFilters({ from: undefined, to: undefined })}>Card periods</button>
          <button type="button" aria-pressed={range} className={range ? "segment segment-active" : "segment"}
            onClick={() => setFilters({ from: `${asOf.slice(0, 7)}-01`, to: asOf })}>Historical range</button>
        </div>
        {!range && <>
          <div className="rw-stepper" role="group" aria-label="As of date" data-past={asOf < today || undefined}>
            <button type="button" className="rw-step" aria-label="Previous day" onClick={() => shiftAsOf(-1)}>‹</button>
            <label className="rw-date">
              <span className="sr-only">As of</span>
              <span className="rw-date-face" aria-hidden="true">{formatDate(asOf)}</span>
              <input type="date" value={asOf} max={today}
                onClick={(event) => { try { event.currentTarget.showPicker?.(); } catch { /* Typing still works. */ } }}
                onChange={(event) => event.target.value && setFilters({ from: undefined, to: event.target.value > today ? today : event.target.value })} />
            </label>
            <button type="button" className="rw-step" aria-label="Next day" disabled={asOf >= today} onClick={() => shiftAsOf(1)}>›</button>
          </div>
          <button type="button" className="rw-tool-button" disabled={asOf >= today} onClick={() => setFilters({ from: undefined, to: undefined })}>Today</button>
          <MultiSelect label="Accounts" options={accounts.map((account) => ({ id: account.id, label: account.name }))}
            selected={filters.accountIds} onChange={(accountIds) => setFilters({ accountIds })} />
        </>}
        <div className="segmented" role="group" aria-label="Cards">
          <button type="button" aria-pressed={!preferences.featured} className={!preferences.featured ? "segment segment-active" : "segment"}
            onClick={() => arrange({ featured: false })}>All cards <span className="rw-count">{storedCards.length}</span></button>
          <button type="button" aria-pressed={preferences.featured} className={preferences.featured ? "segment segment-active" : "segment"}
            onClick={() => arrange({ featured: true })}>Featured <span className="rw-count">{featuredCount}</span></button>
        </div>
        <div className="rw-toolbar-end">
          <ArrangeMenu preferences={preferences} hiddenCount={hiddenCount} onChange={arrange} />
          <button type="button" className="rw-tool-button" aria-pressed={selecting}
            onClick={() => { if (selecting) setSelected([]); setSelecting(!selecting); }}>{selecting ? "Done" : "Select"}</button>
        </div>
      </section>
      <p className="field-note rw-mode-note">{range ? "Rewards attributed to the selected dates; qualification shows the latest card period." : "Each card uses its own billing or reward period. Today uses the server’s Singapore date."} Capped cards stay visible until you hide them.</p>
      {range &&
      <FilterRail
        filters={filters}
        setFilters={setFilters}
        showCategories={false}
        groups={[...GROUPS]}
        busy={report.loading}
      />
      }

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

      {report.loading && !shown && (
        <div className="status-panel">
          <p className="status-title">Loading rewards…</p>
        </div>
      )}

      {emptyImported && (
        <div className="status-panel">
          <p className="status-title">No reward cards in this range.</p>
          <p className="status-detail">
            Import a Rewards Tracker export from <Link to="/import/rewards">Settings → Rewards import</Link>,
            or choose <Link to={addCardHref}>Add card</Link> to score one of your Halation cards.
          </p>
        </div>
      )}

      {emptyForAccounts && (
        <div className="status-panel rw-empty" role="status">
          <p className="status-title">None of the selected accounts has a reward card.</p>
          <button type="button" className="rw-tool-button" onClick={() => setFilters({ accountIds: [] })}>Show all accounts</button>
        </div>
      )}

      {storedCards.length > 0 && (
        <div className="rw-board" data-refreshing={refreshing || undefined} aria-busy={refreshing}>
          {!visibleCards.length && (
            <div className="status-panel rw-empty" role="status">
              {preferences.featured && featuredCount === 0 ? <>
                <p className="status-title">No featured cards.</p>
                <button type="button" className="rw-tool-button" onClick={() => arrange({ featured: false })}>Show all cards</button>
              </> : <>
                <p className="status-title">All cards are hidden.</p>
                <p className="status-detail">Hidden cards still count in the totals above.</p>
                <button type="button" className="rw-tool-button" onClick={() => arrange({ showHidden: true })}>Show hidden cards</button>
              </>}
            </div>
          )}
          {groups.filter((group) => group.rows.length > 0).map((group) => {
            const collapsed = preferences.grouped && preferences.collapsedGroups.includes(group.name);
            return (
              <section key={group.name} className="rw-group" aria-label={group.name}>
                <h2 className="rw-group-head">{preferences.grouped
                  ? <button type="button" className="rw-group-toggle" aria-expanded={!collapsed} aria-controls={`rewards-group-${group.name}`}
                      onClick={() => arrange({ collapsedGroups: collapsed
                        ? preferences.collapsedGroups.filter((name) => name !== group.name) : [...preferences.collapsedGroups, group.name] })}>
                      <span className="rw-group-name">{group.name}</span>
                      <span className="rw-group-count">{group.rows.length}</span>
                      <span className="rw-group-sum">{groupSubtotal(group.rows)}</span>
                      <span className="rw-chevron" aria-hidden="true">▾</span>
                    </button>
                  : <span className="rw-group-name">{group.name}</span>}</h2>
                <div id={`rewards-group-${group.name}`} className="rw-grid" hidden={collapsed}>
                  {group.rows.map((row, index) => (
                    <RewardCard
                      key={row.card.id}
                      row={row}
                      index={index}
                      search={location.search}
                      asOf={shown?.as_of}
                      today={today}
                      selecting={selecting}
                      selected={selected.includes(row.card.id)}
                      busy={batchBusy}
                      justUpdated={justUpdated.includes(row.card.id)}
                      onSelect={(on) => setSelected(on ? [...selected, row.card.id] : selected.filter((id) => id !== row.card.id))}
                      hidden={isHidden(row.card.id)}
                      permanentlyHidden={preferences.hidden.includes(row.card.id)}
                      hiddenUntil={preferences.hiddenUntil[row.card.id]}
                      expiry={nextCardPeriodDate(row)}
                      manual={preferences.order === "manual"}
                      first={index === 0}
                      last={index === group.rows.length - 1}
                      onMove={(direction) => withViewTransition("board", () => moveCard(row.card.id, group.rows[index + direction]!.card.id))}
                      onToggleHidden={() => withViewTransition("board", () => toggleHidden(row.card.id))}
                      onHideUntil={(date) => arrange({ hiddenUntil: { ...preferences.hiddenUntil, [row.card.id]: date } })}
                    />
                  ))}
                </div>
              </section>
            );
          })}
          {hiddenCount > 0 && !preferences.showHidden && visibleCards.length > 0 &&
            <button type="button" className="rw-hidden-footer" onClick={() => arrange({ showHidden: true })}>{hiddenCount} hidden · Show</button>}
          {(selecting || selected.length > 0) && (
            <div className="rw-bulk" role="region" aria-label="Batch card edits">
              <span className="rw-bulk-count" aria-live="polite">{selected.length} selected</span>
              <button type="button" disabled={batchBusy} onClick={selectVisible}>Select visible</button>
              <button type="button" disabled={batchBusy} onClick={() => setSelected([])}>Clear selection</button>
              <span className="rw-bulk-rule" aria-hidden="true" />
              <span className="rw-bulk-verb" aria-hidden="true">Set</span>
              <select aria-label="Batch field" value={batchField} disabled={batchBusy} onChange={(event) => {
                const field = event.target.value as typeof batchField; setBatchField(field); setBatchValue(field === "featured" ? "true" : field === "type" ? "cashback" : "");
              }}><option value="featured">Featured status</option><option value="type">Reward type</option><option value="earningRate">Base earning rate</option></select>
              <span className="rw-bulk-verb" aria-hidden="true">to</span>
              {batchField === "earningRate" ? <input aria-label="Batch value" inputMode="decimal" value={batchValue} onChange={(event) => setBatchValue(event.target.value)} />
                : <select aria-label="Batch value" value={batchValue} onChange={(event) => setBatchValue(event.target.value)}>
                  {batchField === "featured" ? <><option value="true">Featured</option><option value="false">Not featured</option></> : <><option value="cashback">Cashback</option><option value="miles">Miles</option></>}
                </select>}
              <button type="button" className="rw-bulk-apply" disabled={!selected.length || batchBusy} onClick={() => void applyBatch()}>{batchBusy ? "Applying…" : "Apply to selected"}</button>
              <button type="button" onClick={() => { setSelected([]); setSelecting(false); }}>Done</button>
            </div>
          )}
        </div>
      )}

      {shown && (storedCards.length > 0 || shown.groups.length > 0) && (
        <section className="report-section rw-breakdown" aria-labelledby="rewards-groups-heading">
          <div className="section-heading">
            <div>
              <span className="section-title" id="rewards-groups-heading">By {GROUP_LABEL[filters.groupBy].toLowerCase()}</span>
              <span className="section-meta">{shown.groups.length} groups</span>
            </div>
            {!range && (
              <div className="segmented" role="group" aria-label="Report grouping">
                {GROUPS.map((group) => (
                  <button key={group} type="button" aria-pressed={filters.groupBy === group}
                    className={filters.groupBy === group ? "segment segment-active" : "segment"}
                    onClick={() => setFilters({ groupBy: group })}>{GROUP_LABEL[group]}</button>
                ))}
              </div>
            )}
          </div>
          <table className="ledger-table report-table">
            <thead>
              <tr>
                <th>Group</th>
                <th className="num">Spend</th>
                <th className="num">Reward</th>
                <th className="num">Txns</th>
              </tr>
            </thead>
            <tbody>
              {shown.groups.map((row) => (
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
              {shown.groups.length === 0 && (
                <tr><td colSpan={4} className="rw-breakdown-empty">No qualifying transactions</td></tr>
              )}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}

function nextCardPeriodDate(row: RewardsReport["cards"][number]): string | undefined {
  const end = row.calculation.periods?.reduce((latest, period) => period.end > latest ? period.end : latest, "");
  if (!end) return undefined;
  const date = new Date(`${end}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

function Figure({ label, value, primary = false }: { label: string; value: string; primary?: boolean }) {
  return (
    <div className={primary ? "rw-figure rw-figure-primary" : "rw-figure"}>
      <span className="rw-figure-label">{label}</span>
      {/* Keyed by value: a changed figure settles in place (no rolling digits). */}
      <span key={value} className="rw-figure-value figure-settle" data-zero={/[1-9]/.test(value) ? undefined : true}>{value}</span>
    </div>
  );
}

function groupSubtotal(rows: readonly Row[]): string {
  const value = rows.reduce((sum, row) => sum + row.calculation.reward_earned_dollars, 0);
  const miles = rows.reduce((sum, row) => row.calculation.reward_type === "miles" ? sum + row.calculation.reward_earned : sum, 0);
  return miles > 0 ? `${formatReward(miles, "miles")} · ${dollars(value)}` : dollars(value);
}

// R1 tone. R2 replaces cardTone and cardFill with the ported RewardRowProjection.
function cardTone(row: Row): Tone {
  const calc = row.calculation;
  const min = calc.minimum_spend ?? 0;
  const max = calc.maximum_spend ?? 0;
  if (calc.maximum_spend_exceeded) return "complete";
  if (calc.qualification_status === "failed") return "failed";
  if (min > 0 && !calc.minimum_spend_met) return "needs";
  if (min > 0 || max > 0) return "earning";
  return "neutral";
}

/** Which meter leads the slip: the minimum until it is met, then the bonus cap. R2: use projection.basisKind. */
function capIsPrimary(calc: Row["calculation"]): boolean {
  const min = calc.minimum_spend;
  return !(min != null && min > 0 && !calc.minimum_spend_met) && (calc.maximum_spend ?? 0) > 0;
}

/** The primary meter's value, 0 to 1: how far the sun has risen on the face. */
function cardFill(row: Row): number {
  const calc = row.calculation;
  const max = calc.maximum_spend ?? 0;
  const value = capIsPrimary(calc) ? calc.counted_spend / max
    : (calc.minimum_spend ?? 0) > 0 ? (calc.minimum_spend_progress ?? 0) / 100 : 0;
  return clampUnit(value);
}

function clampUnit(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
}

function tierLabel(tiers: Row["card"]["spendingTiers"], id: string, type: "cashback" | "miles"): string {
  const sorted = [...(tiers ?? [])].sort((a, b) => a.spendThreshold - b.spendThreshold);
  const index = sorted.findIndex((tier) => tier.id === id);
  const tier = sorted[index];
  if (!tier) return id;
  const rate = tier.earningRate != null ? ` · ${tier.earningRate}${type === "cashback" ? "%" : " miles/unit"}` : "";
  return `Tier ${index + 1} · from ${dollars(tier.spendThreshold)}${rate}`;
}

type RewardCardProps = {
  row: Row;
  index: number;
  search: string;
  asOf?: string;
  today: string;
  selecting: boolean;
  selected: boolean;
  busy: boolean;
  justUpdated: boolean;
  onSelect: (on: boolean) => void;
  hidden: boolean;
  permanentlyHidden: boolean;
  hiddenUntil?: string;
  expiry?: string;
  manual: boolean;
  first: boolean;
  last: boolean;
  onMove: (direction: -1 | 1) => void;
  onToggleHidden: () => void;
  onHideUntil: (date: string) => void;
};

function RewardCard(p: RewardCardProps) {
  const { row, index, selecting, selected } = p;
  // View-transition names must be idents; ids can start with a digit. Used only while html[data-vt="board"].
  const vt = `rw-${row.card.id.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
  const until = !p.permanentlyHidden && (p.hiddenUntil ?? "") > p.today ? p.hiddenUntil : undefined;
  return (
    <article className="rw-card" data-type={row.card.type} data-tone={cardTone(row)} data-selected={selected || undefined}
      data-hidden={p.hidden || undefined} data-just-updated={p.justUpdated || undefined}
      style={{ "--rw-p": cardFill(row), "--i": Math.min(index, 12), "--vt-name": vt } as CSSProperties}>
      <RewardTile row={row} search={p.search} asOf={p.asOf} hiddenUntil={until} />
      {selecting
        ? <label className="rw-card-select">
            <input type="checkbox" disabled={p.busy} checked={selected} onChange={(event) => p.onSelect(event.target.checked)} />
            <span className="sr-only">Select {row.card.name}</span>
          </label>
        : <div className="rw-card-actions">
            {p.manual && <div role="group" aria-label={`Order ${row.card.name}`} className="rw-order">
              <button type="button" className="rw-icon-button" aria-label={`Move ${row.card.name} up`} disabled={p.first} onClick={() => p.onMove(-1)}>‹</button>
              <button type="button" className="rw-icon-button" aria-label={`Move ${row.card.name} down`} disabled={p.last} onClick={() => p.onMove(1)}>›</button>
            </div>}
            <CardMenu row={row} search={p.search} hidden={p.hidden} expiry={p.expiry} today={p.today}
              onToggleHidden={p.onToggleHidden} onHideUntil={p.onHideUntil} />
          </div>}
    </article>
  );
}

/** A disclosure, not role=menu: a trigger with aria-expanded and a plain list of links and buttons. */
function CardMenu({ row, search, hidden, expiry, today, onToggleHidden, onHideUntil }: {
  row: Row;
  search: string;
  hidden: boolean;
  expiry?: string;
  today: string;
  onToggleHidden: () => void;
  onHideUntil: (date: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  useDismiss(open, () => setOpen(false), root, trigger);
  const returns = expiry && expiry > today ? expiry : undefined;
  return (
    <div className="rw-menu" ref={root}>
      <button ref={trigger} type="button" className="rw-icon-button" aria-label={`Actions for ${row.card.name}`}
        aria-expanded={open} aria-controls={open ? `${id}-list` : undefined} onClick={() => setOpen(!open)}>⋯</button>
      {open && (
        <ul className="rw-menu-list" id={`${id}-list`}>
          <li><Link to={{ pathname: `/rewards/${row.card.id}`, search }}>Edit card</Link></li>
          <li><Link to={`/transactions?accounts=${encodeURIComponent(row.account_id)}&range=all`}>View transactions</Link></li>
          <li>
            <button type="button" aria-describedby={`${id}-device`} onClick={() => { setOpen(false); trigger.current?.focus(); onToggleHidden(); }}>{hidden ? "Unhide" : "Hide"}</button>
            <span className="rw-menu-note" id={`${id}-device`}>On this device</span>
          </li>
          {!hidden && (
            <li>
              <button type="button" aria-label={`Hide ${row.card.name} until next period`} aria-describedby={`${id}-returns`}
                disabled={!expiry || expiry <= today}
                title={expiry && expiry > today ? `Returns ${expiry} (Singapore)` : "No upcoming period boundary in this report"}
                onClick={() => { if (!expiry) return; setOpen(false); trigger.current?.focus(); onHideUntil(expiry); }}>Hide until next period</button>
              <span className="rw-menu-note" id={`${id}-returns`}>{returns ? `Returns ${formatDate(returns)}` : "No upcoming period boundary in this report"}</span>
            </li>
          )}
        </ul>
      )}
    </div>
  );
}

/** The Order radiogroup, Group by type, Show hidden and the import link, in one popover. */
function ArrangeMenu({ preferences, hiddenCount, onChange }: {
  preferences: BoardPreferences;
  hiddenCount: number;
  onChange: (patch: Partial<BoardPreferences>) => void;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  useDismiss(open, () => setOpen(false), root, trigger);
  return (
    <div className="rw-popover-wrap" ref={root}>
      <button ref={trigger} type="button" className="rw-tool-button rw-arrange" aria-expanded={open}
        aria-controls={open ? `${id}-arrange` : undefined} onClick={() => setOpen(!open)}>
        Arrange · {ORDER_LABEL[preferences.order]}
        {preferences.showHidden && <><span className="rw-dot" aria-hidden="true" /><span className="sr-only">, showing hidden cards</span></>}
        <span className="caret" aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className="rw-popover" id={`${id}-arrange`}>
          <fieldset className="rw-fieldset">
            <legend>Order</legend>
            {ORDERS.map((order) => (
              <label key={order} className="rw-option">
                <input type="radio" name={`${id}-order`} value={order} checked={preferences.order === order} onChange={() => onChange({ order })} />
                {ORDER_LABEL[order]}
              </label>
            ))}
          </fieldset>
          <div className="rw-popover-rule" aria-hidden="true" />
          <label className="rw-option">
            <input type="checkbox" checked={preferences.grouped} onChange={(event) => onChange({ grouped: event.target.checked })} /> Group by type
          </label>
          <label className="rw-option">
            <input type="checkbox" checked={preferences.showHidden} onChange={(event) => onChange({ showHidden: event.target.checked })} /> Show hidden ({hiddenCount})
          </label>
          <div className="rw-popover-rule" aria-hidden="true" />
          <Link className="rw-popover-link" to="/import/rewards">Import or export…</Link>
        </div>
      )}
    </div>
  );
}

function ExposureMeter({ primary, tone, label, figure, value, ariaLabel }: {
  primary: boolean;
  tone: Tone;
  label: string;
  /** One string so "167.00 / 100.00" stays contiguous in the markup. */
  figure: string;
  value: number;
  ariaLabel: string;
}) {
  const fill = clampUnit(value);
  const percent = Math.round(fill * 100);
  return (
    <div className={primary ? "rw-meter rw-meter-primary" : "rw-meter"} data-tone={tone} style={{ "--rw-m": fill } as CSSProperties}>
      <div className="rw-meter-legend"><span>{label}</span><span>{figure}</span></div>
      <div className="rw-meter-track" role="progressbar" aria-label={ariaLabel} aria-valuemin={0} aria-valuemax={100}
        aria-valuenow={percent} aria-valuetext={`${figure}, ${percent} per cent`}>
        <span className="rw-meter-fill" />
        {primary && <span className="rw-meter-bead" />}
      </div>
    </div>
  );
}

// Signature stays compatible with lib/rewards-tile.test.ts: ({ row, search, asOf }) still works.
export function RewardTile({ row, search, asOf, hiddenUntil }: { row: Row; search: string; asOf?: string; hiddenUntil?: string }) {
  const calc = row.calculation;
  const id = useId();
  // Historical amounts are range-attributed, while qualification belongs to the
  // cutoff period. An earlier promotion may sort after that calendar period.
  const fullPeriod = calc.periods?.filter((period) => asOf && period.start <= asOf && period.end >= asOf).at(-1)?.calculation;
  const min = calc.minimum_spend;
  const max = calc.maximum_spend ?? 0;
  const capPrimary = capIsPrimary(calc);
  return (
    <>
      <Link to={{ pathname: `/rewards/${row.card.id}`, search }} className="rw-tile" aria-labelledby={`${id}-name`}>
        <div className="rw-face">
          <span className="rw-face-halo" aria-hidden="true" />
          <span className="rw-face-sun" aria-hidden="true" />
          <svg className="rw-face-ridge" viewBox="0 400 1024 624" preserveAspectRatio="none" aria-hidden="true">
            <path className="rw-ridge-back" d="M0 664 C110 646 196 606 296 612 C396 618 452 546 556 524 C656 502 724 470 822 444 C898 424 962 434 1024 402 L1024 1024 L0 1024 Z" />
            <path className="rw-ridge-front" d="M0 820 C96 806 176 782 258 792 C336 801 372 738 462 722 C534 709 574 748 648 728 C758 698 818 634 898 612 C950 598 988 602 1024 584 L1024 1024 L0 1024 Z" />
            <path className="rw-ridge-crest" d="M0 820 C96 806 176 782 258 792 C336 801 372 738 462 722 C534 709 574 748 648 728 C758 698 818 634 898 612 C950 598 988 602 1024 584" />
          </svg>
          <p className="rw-face-top">
            <span>{[row.card.issuer, row.card.type === "miles" ? "Miles" : "Cashback"].filter(Boolean).join(" · ")}</span>
            {row.card.featured && <span className="rw-badge" title="Featured">✦<span className="sr-only"> Featured</span></span>}
            {hiddenUntil && (
              <span className="rw-badge" title={`Hidden until ${hiddenUntil} (Singapore)`}>
                Back {formatDate(hiddenUntil)}<span className="sr-only"> Hidden until {hiddenUntil} (Singapore)</span>
              </span>
            )}
          </p>
          <h3 className="rw-face-name" id={`${id}-name`}>{row.card.name}</h3>
          <p className="rw-face-foot">
            <span className="rw-face-account">{row.account_name}</span>
            <span className="rw-face-earned">{formatReward(calc.reward_earned, calc.reward_type)}</span>
          </p>
        </div>
        <div className="rw-slip">
          {/* R2: <p className="rw-headline" data-urgent>…amount… actionLabel <span className="rw-deadline">…</span></p> */}
          {min != null && min > 0 && (
            <ExposureMeter
              primary={!capPrimary}
              tone={calc.minimum_spend_met ? "earning" : "needs"}
              label={fullPeriod ? (calc.minimum_spend_met ? "Full-period minimum met" : "Full-period minimum") : (calc.minimum_spend_met ? "Minimum met" : "Minimum spend")}
              figure={`${dollars(fullPeriod?.total_spend ?? calc.total_spend)} / ${dollars(min)}`}
              value={(calc.minimum_spend_progress ?? 0) / 100}
              ariaLabel="Minimum spend progress"
            />
          )}
          {max > 0 && (
            <ExposureMeter
              primary={capPrimary}
              tone={calc.maximum_spend_exceeded ? "complete" : "earning"}
              label={calc.maximum_spend_exceeded ? "Cap reached" : "Bonus cap"}
              figure={`${dollars(Math.min(calc.counted_spend, max))} / ${dollars(max)}`}
              value={calc.counted_spend / max}
              ariaLabel="Bonus cap used"
            />
          )}
          {calc.has_next_spending_tier && calc.next_spending_tier_threshold != null && <p className="rw-line">Next tier at {dollars(calc.next_spending_tier_threshold)}</p>}
          {calc.should_stop_using && <p className="rw-line rw-line-strong">Consider another card</p>}
          <dl className="rw-stats">
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
          {calc.flags.length > 0 && (
            <ul className="rw-flags">
              {calc.flags.map((flag) => {
                const cap = flag.maximumSpend ?? 0;
                const counted = flag.countedSpend ?? flag.totalSpend;
                const use = cap > 0 ? clampUnit(counted / cap) : 0;
                return (
                  <li key={flag.subcategoryId} className="rw-flag" data-warn={use >= 0.9 || undefined} style={{ "--use": use } as CSSProperties}>
                    {isFlagColour(flag.flagColor)
                      ? <FlagTag colour={flag.flagColor} name={flag.name} />
                      : <span>{flag.name}</span>}
                    <span>{flag.rewardRate != null ? `${flag.rewardRate}${calc.reward_type === "cashback" ? "%" : " miles/unit"}` : ""}</span>
                    <span className="num">{formatReward(flag.rewardEarned, calc.reward_type)}</span>
                    {cap > 0 && <span className="rw-flag-cap">{dollars(counted)} / {dollars(cap)} cap</span>}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </Link>
      <details className="rw-more">
        <summary>Periods and tiers</summary>
        <p>Period: {calc.periods?.map((period) => `${formatDate(period.start)} – ${formatDate(period.end)}`).join("; ") || calc.period}</p>
        {calc.qualification_status && <p>Monthly qualification: {calc.qualification_status.replaceAll("_", " ")}</p>}
        {calc.monthly_qualifications?.length ? (
          <ol className="rw-months">
            {calc.monthly_qualifications.map((month) => (
              <li key={month.start} data-status={month.status}>
                {formatDate(month.start)} – {formatDate(month.end)}: {dollars(month.spend)} / {dollars(month.minimumSpend)} · {month.status}
              </li>
            ))}
          </ol>
        ) : null}
        {calc.active_spending_tier_id != null && <p>Active tier: {tierLabel(row.card.spendingTiers, calc.active_spending_tier_id, calc.reward_type)}</p>}
      </details>
    </>
  );
}

function formatReward(amount: number, type: "cashback" | "miles" | undefined): string {
  if (type === "miles") return `${Math.round(amount).toLocaleString("en-GB")} mi`;
  return dollars(amount);
}
