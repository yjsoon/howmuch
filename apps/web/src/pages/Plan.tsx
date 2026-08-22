import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { CategoryGroup, PlanMonthCategory } from "../api/types";
import { isQuietGroup, isQuietGroupName } from "../lib/categories";
import { formatMilliunitsInput, formatMoney, parseMilliunits } from "../lib/money";
import { usePlan } from "../state/plan";

interface PlanGroup {
  id: string;
  name: string;
  quiet: boolean;
  categories: PlanMonthCategory[];
}

export function PlanPage() {
  const { planId, categoryGroups } = usePlan();
  const [month, setMonth] = useState(currentMonth());
  const [showQuiet, setShowQuiet] = useState(false);
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set());
  const [revision, setRevision] = useState(0);
  const [editing, setEditing] = useState<{ categoryId: string; value: string } | null>(null);
  const [editingTarget, setEditingTarget] = useState<{ categoryId: string; value: string; type: string; month: string } | null>(null);
  const [savingCategoryId, setSavingCategoryId] = useState<string | null>(null);
  const [planError, setPlanError] = useState<string | null>(null);
  const result = useApi(`${planId}:${month}:${revision}`, () => api.month(planId, month));

  const groups = useMemo(() => groupMonth(result.data?.categories ?? [], categoryGroups), [result.data, categoryGroups]);
  const primaryGroups = groups.filter((group) => !group.quiet);
  const quietGroups = groups.filter((group) => group.quiet);
  const toggleGroup = (id: string) => {
    setCollapsed((previous) => {
      const next = new Set(previous);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };
  const startAssignment = (category: PlanMonthCategory) => {
    setPlanError(null);
    setEditing({ categoryId: category.id, value: formatMilliunitsInput(category.budgeted ?? 0) });
  };
  const saveAssignment = async (category: PlanMonthCategory) => {
    if (!editing || editing.categoryId !== category.id) return;
    const budgeted = parseMilliunits(editing.value);
    if (budgeted === null) {
      setPlanError("Enter a valid amount with no more than three decimal places.");
      return;
    }
    setSavingCategoryId(category.id);
    setPlanError(null);
    try {
      await api.setMonthCategoryAssignment(planId, month, category.id, budgeted);
      setEditing(null);
      setRevision((value) => value + 1);
    } catch (cause) {
      setPlanError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setSavingCategoryId(null);
    }
  };
  const startTarget = (category: PlanMonthCategory) => {
    setPlanError(null);
    setEditingTarget({
      categoryId: category.id,
      value: formatMilliunitsInput(category.goal_target ?? 0),
      type: category.goal_type ?? "TB",
      month: category.goal_target_month?.slice(0, 7) ?? "",
    });
  };
  const saveTarget = async (category: PlanMonthCategory) => {
    if (!editingTarget || editingTarget.categoryId !== category.id) return;
    const target = parseMilliunits(editingTarget.value);
    if (target === null || target <= 0) {
      setPlanError("Enter a target amount greater than zero with no more than three decimal places.");
      return;
    }
    if (editingTarget.month && !/^\d{4}-(0[1-9]|1[0-2])$/.test(editingTarget.month)) {
      setPlanError("Use YYYY-MM for the optional target month.");
      return;
    }
    setSavingCategoryId(category.id); setPlanError(null);
    try {
      await api.setMonthCategoryTarget(planId, month, category.id, {
        goal_type: editingTarget.type,
        goal_target: target,
        goal_target_month: editingTarget.month || null,
      });
      setEditingTarget(null); setRevision((value) => value + 1);
    } catch (cause) {
      setPlanError(cause instanceof Error ? cause.message : String(cause));
    } finally { setSavingCategoryId(null); }
  };
  const clearTarget = async (category: PlanMonthCategory) => {
    setSavingCategoryId(category.id); setPlanError(null);
    try {
      await api.setMonthCategoryTarget(planId, month, category.id, null);
      setEditingTarget(null); setRevision((value) => value + 1);
    } catch (cause) { setPlanError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setSavingCategoryId(null); }
  };
  const restoreTarget = async (category: PlanMonthCategory) => {
    setSavingCategoryId(category.id); setPlanError(null);
    try {
      await api.restoreMonthCategoryTarget(planId, month, category.id);
      setEditingTarget(null); setRevision((value) => value + 1);
    } catch (cause) { setPlanError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setSavingCategoryId(null); }
  };

  return (
    <>
      <header className="report-header plan-header">
        <div>
          <span className="page-eyebrow">Monthly plan</span>
          <h1>Plan</h1>
        </div>
        <div className="month-stepper" role="group" aria-label="Plan month">
          <button type="button" className="month-step" onClick={() => setMonth((value) => shiftMonth(value, -1))} aria-label="Previous month">‹</button>
          <span className="month-label">{formatMonth(month)}</span>
          <button
            type="button"
            className="month-current"
            onClick={() => setMonth(currentMonth())}
            disabled={month === currentMonth()}
          >
            Current
          </button>
          <button
            type="button"
            className="month-step"
            onClick={() => setMonth((value) => shiftMonth(value, 1))}
            aria-label="Next month"
          >
            ›
          </button>
        </div>
      </header>

      {result.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load this month’s plan.</p>
          <p className="status-detail">{result.error}</p>
        </div>
      )}
      {result.loading && !result.data && (
        <div className="status-panel"><p className="status-title">Loading monthly plan…</p></div>
      )}

      {result.data && (
        <>
          <section className="plan-summary" aria-label="Plan summary">
            <PlanFigure label="Ready to assign" amount={result.data.to_be_budgeted ?? 0} tone={(result.data.to_be_budgeted ?? 0) < 0 ? "negative" : "accent"} />
            <PlanFigure label="Assigned" amount={result.data.budgeted ?? 0} />
            <PlanFigure label="Activity" amount={result.data.activity ?? 0} tone={(result.data.activity ?? 0) < 0 ? "negative" : "positive"} />
          </section>

          <p className="diagnostic-note">Assignments and targets are saved in HowMuch. Imported YNAB values are preserved and can be restored.</p>
          {planError && <div className="status-panel status-panel-error compact-panel"><p className="status-title">Plan change was not saved.</p><p className="status-detail">{planError}</p></div>}

          {primaryGroups.map((group) => (
            <PlanGroupTable
              key={group.id} group={group} month={month} collapsed={collapsed.has(group.id)} onToggle={() => toggleGroup(group.id)}
              editing={editing} savingCategoryId={savingCategoryId} onStartAssignment={startAssignment}
              onChangeAssignment={(value) => setEditing((current) => current ? { ...current, value } : current)}
              onSaveAssignment={saveAssignment} onCancelAssignment={() => setEditing(null)}
              editingTarget={editingTarget} onStartTarget={startTarget}
              onChangeTarget={(patch) => setEditingTarget((current) => current ? { ...current, ...patch } : current)}
              onSaveTarget={saveTarget} onClearTarget={clearTarget} onRestoreTarget={restoreTarget} onCancelTarget={() => setEditingTarget(null)}
            />
          ))}

          {quietGroups.length > 0 && (
            <section className="plan-quiet-section">
              <button type="button" className="plan-quiet-toggle" onClick={() => setShowQuiet((value) => !value)} aria-expanded={showQuiet}>
                {showQuiet ? "Hide bookkeeping categories" : "Show bookkeeping categories"}
                <span aria-hidden="true">{showQuiet ? "⌃" : "⌄"}</span>
              </button>
              {showQuiet && quietGroups.map((group) => (
                <PlanGroupTable
                  key={group.id} group={group} month={month} collapsed={collapsed.has(group.id)} onToggle={() => toggleGroup(group.id)}
                  editing={editing} savingCategoryId={savingCategoryId} onStartAssignment={startAssignment}
                  onChangeAssignment={(value) => setEditing((current) => current ? { ...current, value } : current)}
                  onSaveAssignment={saveAssignment} onCancelAssignment={() => setEditing(null)}
                  editingTarget={editingTarget} onStartTarget={startTarget}
                  onChangeTarget={(patch) => setEditingTarget((current) => current ? { ...current, ...patch } : current)}
                  onSaveTarget={saveTarget} onClearTarget={clearTarget} onRestoreTarget={restoreTarget} onCancelTarget={() => setEditingTarget(null)}
                />
              ))}
            </section>
          )}

          {groups.length === 0 && (
            <div className="status-panel">
              <p className="status-title">No categories in this month.</p>
              <p className="status-detail">The imported plan has no active category rows for {formatMonth(month)}.</p>
            </div>
          )}
        </>
      )}
    </>
  );
}

function PlanFigure({ label, amount, tone }: { label: string; amount: number; tone?: "accent" | "positive" | "negative" }) {
  return (
    <div className="headline-figure">
      <span className="figure-label">{label}</span>
      <span className={`figure-value ${tone === "negative" ? "figure-negative" : tone === "positive" ? "figure-positive" : tone === "accent" ? "plan-figure-accent" : ""}`}>{formatMoney(amount)}</span>
    </div>
  );
}

function PlanGroupTable({
  group, month, collapsed, onToggle, editing, savingCategoryId, onStartAssignment, onChangeAssignment, onSaveAssignment, onCancelAssignment,
  editingTarget, onStartTarget, onChangeTarget, onSaveTarget, onClearTarget, onRestoreTarget, onCancelTarget,
}: {
  group: PlanGroup;
  month: string;
  collapsed: boolean;
  onToggle: () => void;
  editing: { categoryId: string; value: string } | null;
  savingCategoryId: string | null;
  onStartAssignment: (category: PlanMonthCategory) => void;
  onChangeAssignment: (value: string) => void;
  onSaveAssignment: (category: PlanMonthCategory) => void;
  onCancelAssignment: () => void;
  editingTarget: { categoryId: string; value: string; type: string; month: string } | null;
  onStartTarget: (category: PlanMonthCategory) => void;
  onChangeTarget: (patch: Partial<{ value: string; type: string; month: string }>) => void;
  onSaveTarget: (category: PlanMonthCategory) => void;
  onClearTarget: (category: PlanMonthCategory) => void;
  onRestoreTarget: (category: PlanMonthCategory) => void;
  onCancelTarget: () => void;
}) {
  const available = group.categories.reduce((total, category) => total + (category.balance ?? 0), 0);
  return (
    <section className="report-section plan-group">
      <div className="section-heading">
        <button type="button" className="plan-group-toggle" onClick={onToggle} aria-expanded={!collapsed}>
          <span aria-hidden="true">{collapsed ? "›" : "⌄"}</span>
          <span className="section-title">{group.name}</span>
        </button>
        <span className={available < 0 ? "section-meta amount-negative" : "section-meta amount-positive"}>{formatMoney(available)} available</span>
      </div>
      {!collapsed && (
        <div className="table-wrap table-wrap-wide">
          <table className="ledger-table plan-table">
            <thead>
              <tr>
                <th>Category</th>
                <th className="num">Assigned</th>
                <th className="num">Activity</th>
                <th className="num">Available</th>
                <th>Target</th>
              </tr>
            </thead>
            <tbody>
              {group.categories.map((category) => {
                const target = targetState(category);
                return (
                  <tr key={category.id}>
                    <td><Link className="drill-link" to={categoryTransactionsLink(month, category.id)}>{category.name}</Link></td>
                    <td className="num plan-assignment-cell">
                      {editing?.categoryId === category.id ? (
                        <form className="plan-assignment-form" onSubmit={(event) => { event.preventDefault(); void onSaveAssignment(category); }}>
                          <input
                            aria-label={`Assigned amount for ${category.name}`}
                            autoFocus
                            inputMode="decimal"
                            value={editing.value}
                            onChange={(event) => onChangeAssignment(event.target.value)}
                          />
                          <button type="submit" className="plan-assignment-save" disabled={savingCategoryId === category.id}>{savingCategoryId === category.id ? "Saving" : "Save"}</button>
                          <button type="button" className="plan-assignment-cancel" onClick={onCancelAssignment} disabled={savingCategoryId === category.id}>Cancel</button>
                        </form>
                      ) : (
                        <button type="button" className="plan-assignment-button" onClick={() => onStartAssignment(category)} aria-label={`Edit assigned amount for ${category.name}`}>
                          {formatMoney(category.budgeted ?? 0)}
                        </button>
                      )}
                    </td>
                    <td className={`num ${(category.activity ?? 0) < 0 ? "amount-negative" : "amount-positive"}`}>{formatMoney(category.activity ?? 0)}</td>
                    <td className={`num strong ${(category.balance ?? 0) < 0 ? "amount-negative" : "amount-positive"}`}>{formatMoney(category.balance ?? 0)}</td>
                    <td className="plan-target-cell">
                      {editingTarget?.categoryId === category.id ? (
                        <form className="plan-target-form" onSubmit={(event) => { event.preventDefault(); void onSaveTarget(category); }}>
                          <select aria-label={`Target type for ${category.name}`} value={editingTarget.type} onChange={(event) => onChangeTarget({ type: event.target.value })}>
                            <option value="TB">Savings balance</option><option value="TBD">By date</option><option value="MF">Monthly spending</option><option value="NEED">Needed for spending</option><option value="DEBT">Debt payoff</option>
                          </select>
                          <input aria-label={`Target amount for ${category.name}`} inputMode="decimal" value={editingTarget.value} onChange={(event) => onChangeTarget({ value: event.target.value })} />
                          <input aria-label={`Target month for ${category.name}`} placeholder="YYYY-MM" value={editingTarget.month} onChange={(event) => onChangeTarget({ month: event.target.value })} />
                          <button type="submit" className="plan-assignment-save" disabled={savingCategoryId === category.id}>{savingCategoryId === category.id ? "Saving" : "Save"}</button>
                          <button type="button" className="plan-assignment-cancel" onClick={onCancelTarget} disabled={savingCategoryId === category.id}>Cancel</button>
                          <button type="button" className="plan-target-clear" onClick={() => void onClearTarget(category)} disabled={savingCategoryId === category.id}>Clear</button>
                          {category.target_source && <button type="button" className="plan-target-restore" onClick={() => void onRestoreTarget(category)} disabled={savingCategoryId === category.id}>Restore imported</button>}
                        </form>
                      ) : (
                        <button type="button" className="plan-target-button" onClick={() => onStartTarget(category)} aria-label={`Edit target for ${category.name}`}>
                          {target ? <TargetState label={target.label} progress={target.progress} complete={target.complete} /> : "Set target"}
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function TargetState({ label, progress, complete }: { label: string; progress: number | null; complete: boolean }) {
  return (
    <div className={complete ? "plan-target plan-target-complete" : "plan-target"}>
      <span>{label}</span>
      {progress !== null && <span className="plan-target-track" aria-label={`${label} progress`}><span className="plan-target-fill" style={{ width: `${progress * 100}%` }} /></span>}
    </div>
  );
}

function targetState(category: PlanMonthCategory): { label: string; progress: number | null; complete: boolean } | null {
  const hasTarget = category.goal_type != null || (category.goal_target ?? 0) > 0;
  if (!hasTarget) return null;
  const progress = category.goal_percentage_complete != null
    ? clamp(category.goal_percentage_complete / 100)
    : category.goal_target && category.goal_target > 0
      ? clamp((category.balance ?? 0) / category.goal_target)
      : null;
  return {
    label: progress !== null && progress >= 1 ? "Target met" : progress !== null ? `Target ${Math.round(progress * 100)}%` : "Target set",
    progress,
    complete: progress !== null && progress >= 1,
  };
}

function groupMonth(categories: PlanMonthCategory[], references: CategoryGroup[]): PlanGroup[] {
  const remaining = new Map<string, PlanMonthCategory[]>();
  for (const category of categories) {
    if (category.deleted) continue;
    const group = remaining.get(category.category_group_id) ?? [];
    group.push(category);
    remaining.set(category.category_group_id, group);
  }
  const result: PlanGroup[] = [];
  for (const reference of references) {
    const categoriesForGroup = remaining.get(reference.id);
    if (!categoriesForGroup?.length || reference.deleted) continue;
    remaining.delete(reference.id);
    result.push({ id: reference.id, name: reference.name, quiet: isQuietGroup(reference), categories: sortCategories(categoriesForGroup) });
  }
  for (const [id, categoriesForGroup] of [...remaining.entries()].sort(([left], [right]) => left.localeCompare(right))) {
    const name = "Uncategorised group";
    result.push({ id, name, quiet: isQuietGroupName(name), categories: sortCategories(categoriesForGroup) });
  }
  return result;
}

function sortCategories(categories: PlanMonthCategory[]): PlanMonthCategory[] {
  return [...categories].sort((left, right) => left.name.localeCompare(right.name));
}

function currentMonth(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
}

function shiftMonth(month: string, delta: number): string {
  const [year, monthNumber] = month.split("-").map(Number);
  const shifted = new Date(year, monthNumber - 1 + delta, 1);
  return `${shifted.getFullYear()}-${String(shifted.getMonth() + 1).padStart(2, "0")}`;
}

function formatMonth(month: string): string {
  const [year, monthNumber] = month.split("-").map(Number);
  return new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(year, monthNumber - 1, 1)));
}

function categoryTransactionsLink(month: string, categoryId: string): string {
  const [year, monthNumber] = month.split("-").map(Number);
  const lastDay = new Date(year, monthNumber, 0).getDate();
  return `/transactions?from=${month}-01&to=${month}-${String(lastDay).padStart(2, "0")}&accounts=all&categories=${encodeURIComponent(categoryId)}&flow=outflow`;
}

function clamp(value: number): number {
  return Math.min(1, Math.max(0, value));
}

