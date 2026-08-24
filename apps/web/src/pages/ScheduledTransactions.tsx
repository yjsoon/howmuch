import { useMemo, useState } from "react";
import { api, useApi } from "../api/client";
import type { Account, CategoryGroup, Payee, ScheduledSubtransaction, ScheduledTransaction, ScheduledTransactionInput } from "../api/types";
import { CategorySelect } from "../components/CategorySelect";
import { FlagPicker, FlagTag } from "../components/FlagTag";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate, todayIso } from "../lib/dates";
import { stableHash } from "../lib/hash";
import { formatMilliunitsInput, formatMoney, parseMilliunits } from "../lib/money";
import { scheduleRecurrence } from "../lib/schedules";
import { usePlan } from "../state/plan";

type ScheduleGroup = { date: string; schedules: ScheduledTransaction[] };
type EditorState = { mode: "create" } | { mode: "edit"; schedule: ScheduledTransaction };
type PendingDeletion = { schedule: ScheduledTransaction; idempotencyKey: string };
type PendingEntry = { schedule: ScheduledTransaction; occurrenceDate: string; enteredDate: string; operationSeed: string; idempotencyKey: string };
type SplitDraft = { key: string; sourceId?: string; amount: string; payeeId: string; categoryId: string; transferAccountId: string; memo: string };

/** Future recurring transactions, with local overlays for imported YNAB rows. */
export function ScheduledTransactionsPage() {
  const { accounts, categoryGroups, categoryNames, planId, reload } = usePlan();
  const [generation, setGeneration] = useState(0);
  const [editor, setEditor] = useState<EditorState | null>(null);
  const [pendingDeletion, setPendingDeletion] = useState<PendingDeletion | null>(null);
  const [pendingEntry, setPendingEntry] = useState<PendingEntry | null>(null);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [mutationSuccess, setMutationSuccess] = useState<string | null>(null);
  const [mutatingId, setMutatingId] = useState<string | null>(null);
  const schedules = useApi(`${planId}:scheduled:${generation}`, () => api.scheduledTransactions(planId));
  const payees = useApi(`${planId}:scheduled-payees`, () => api.payees(planId));
  const active = useMemo(
    () => (schedules.data ?? []).filter((schedule) => !schedule.deleted).sort(compareSchedules),
    [schedules.data],
  );
  const groups = useMemo(() => groupSchedules(active), [active]);
  const accountNames = useMemo(() => new Map(accounts.map((account) => [account.id, account.name])), [accounts]);
  const payeeNames = useMemo(() => new Map((payees.data ?? []).map((payee) => [payee.id, payee.name])), [payees.data]);
  const nextDate = groups[0]?.date;
  const refresh = () => setGeneration((value) => value + 1);

  const saveSchedule = async (input: ScheduledTransactionInput, idempotencyKey: string) => {
    const mutationId = editor?.mode === "edit" ? editor.schedule.id : "creating";
    setMutatingId(mutationId);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      if (editor?.mode === "edit") {
        await api.updateScheduledTransaction(planId, editor.schedule.id, input, idempotencyKey);
      } else {
        await api.createScheduledTransaction(planId, input, idempotencyKey);
      }
      setEditor(null);
      refresh();
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setMutatingId(null);
    }
  };

  const deleteSchedule = async ({ schedule, idempotencyKey }: PendingDeletion) => {
    setMutatingId(schedule.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await api.deleteScheduledTransaction(planId, schedule.id, idempotencyKey);
      setPendingDeletion(null);
      if (editor?.mode === "edit" && editor.schedule.id === schedule.id) setEditor(null);
      refresh();
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setMutatingId(null);
    }
  };

  const enterScheduleNow = async (entry: PendingEntry) => {
    setMutatingId(entry.schedule.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      const result = await api.materializeScheduledTransaction(
        planId,
        entry.schedule.id,
        entry.occurrenceDate,
        entry.enteredDate,
        entry.idempotencyKey,
      );
      setPendingEntry(null);
      setMutationSuccess(
        result.completed
          ? `Entered ${formatDate(result.occurrence_date)} on ${formatDate(result.entered_date)}. This one-off schedule is complete.`
          : `Entered ${formatDate(result.occurrence_date)} on ${formatDate(result.entered_date)}. The schedule has advanced.`,
      );
      reload();
      refresh();
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setMutatingId(null);
    }
  };

  return (
    <>
      <header className="report-header schedule-header">
        <div>
          <span className="page-eyebrow">Future ledger</span>
          <h1>Scheduled transactions</h1>
        </div>
        <div className="headline-row schedule-figures" aria-label="Schedule summary">
          <Figure label="Active schedules" value={String(active.length)} />
          <Figure label="Next due" value={nextDate ? formatDate(nextDate) : "—"} />
          <button
            type="button"
            className="register-add-link"
            onClick={() => { setEditor({ mode: "create" }); setMutationError(null); setMutationSuccess(null); }}
            disabled={Boolean(mutatingId)}
          >
            Add schedule
          </button>
        </div>
      </header>

      <p className="diagnostic-note">Changes stay in HowMuch and leave the imported YNAB schedule intact.</p>

      {mutationError && <div className="status-panel status-panel-error" role="alert"><p className="status-title">Could not update scheduled transactions.</p><p className="status-detail">{mutationError}</p></div>}
      {mutationSuccess && <div className="status-panel" role="status"><p className="status-title">{mutationSuccess}</p></div>}
      {editor && (
        <ScheduleEditor
          schedule={editor.mode === "edit" ? editor.schedule : undefined}
          accounts={accounts}
          categoryGroups={categoryGroups}
          payees={payees.data ?? []}
          saving={mutatingId === "creating" || (editor.mode === "edit" && mutatingId === editor.schedule.id)}
          onCancel={() => { setEditor(null); setMutationError(null); }}
          onSave={saveSchedule}
        />
      )}
      {pendingDeletion && (
        <section className="transaction-editor schedule-delete-confirm" aria-labelledby="delete-schedule-heading">
          <div className="section-heading"><div><span className="section-title" id="delete-schedule-heading">Delete scheduled transaction?</span><span className="section-meta">This stops future instances in HowMuch.</span></div></div>
          <p>{scheduleLabel(pendingDeletion.schedule, payeeNames, accountNames)} is due next on {pendingDeletion.schedule.date_next ? formatDate(pendingDeletion.schedule.date_next) : "its configured date"}.</p>
          <div className="transaction-editor-actions">
            <button type="button" className="text-button" onClick={() => setPendingDeletion(null)} disabled={mutatingId === pendingDeletion.schedule.id}>Cancel</button>
            <button type="button" className="save-button schedule-delete-button" onClick={() => void deleteSchedule(pendingDeletion)} disabled={mutatingId === pendingDeletion.schedule.id}>{mutatingId === pendingDeletion.schedule.id ? "Deleting…" : "Delete schedule"}</button>
          </div>
        </section>
      )}
      {pendingEntry && (
        <section className="transaction-editor schedule-enter-confirm" aria-labelledby="enter-schedule-heading">
          <div className="section-heading"><div><span className="section-title" id="enter-schedule-heading">Enter scheduled transaction now?</span><span className="section-meta">This creates one real ledger transaction and advances the schedule.</span></div></div>
          <p><strong>{scheduleLabel(pendingEntry.schedule, payeeNames, accountNames)}</strong> is scheduled for {formatDate(pendingEntry.occurrenceDate)}.</p>
          <label className="field">
            <span className="field-label">Register date</span>
            <input
              type="date"
              value={pendingEntry.enteredDate}
              onChange={(event) => setPendingEntry((current) => current ? {
                ...current,
                enteredDate: event.target.value,
                idempotencyKey: materializationKey(current.schedule.id, current.occurrenceDate, event.target.value, current.operationSeed),
              } : current)}
              required
            />
            <span className="field-note">Defaults to today on this device. The schedule still advances from {formatDate(pendingEntry.occurrenceDate)}.</span>
          </label>
          <div className="transaction-editor-actions">
            <button type="button" className="text-button" onClick={() => setPendingEntry(null)} disabled={mutatingId === pendingEntry.schedule.id}>Cancel</button>
            <button type="button" className="save-button" onClick={() => void enterScheduleNow(pendingEntry)} disabled={mutatingId === pendingEntry.schedule.id || !pendingEntry.enteredDate}>{mutatingId === pendingEntry.schedule.id ? "Entering…" : "Enter now"}</button>
          </div>
        </section>
      )}

      {schedules.error && <div className="status-panel status-panel-error" role="alert"><p className="status-title">Could not load scheduled transactions.</p><p className="status-detail">{schedules.error}</p></div>}
      {schedules.loading && !schedules.data && <div className="status-panel"><p className="status-title">Loading scheduled transactions…</p></div>}
      {!schedules.loading && !schedules.error && active.length === 0 && !editor && (
        <div className="status-panel"><p className="status-title">No active schedules.</p><p className="status-detail">Add a recurring transaction to keep upcoming spending and income visible.</p></div>
      )}

      {groups.map((group) => (
        <section key={group.date} className="report-section schedule-section" aria-labelledby={`schedule-date-${group.date}`}>
          <div className="section-heading"><h2 id={`schedule-date-${group.date}`} className="section-title">{formatDate(group.date)}</h2><span className="section-meta">{group.schedules.length} {group.schedules.length === 1 ? "schedule" : "schedules"}</span></div>
          <div className="table-wrap table-wrap-wide">
            <table className="ledger-table schedule-table"><thead><tr><th>Next</th><th>Payee / memo</th><th>Account</th><th>Category</th><th>Repeat</th><th className="num">Amount</th><th><span className="sr-only">Actions</span></th></tr></thead>
              <tbody>{group.schedules.map((schedule) => <ScheduleRows key={schedule.id} schedule={schedule} accounts={accountNames} categories={categoryNames} payees={payeeNames} busy={mutatingId === schedule.id} onEdit={() => { setEditor({ mode: "edit", schedule }); setMutationError(null); setMutationSuccess(null); }} onEnter={() => { if (!schedule.date_next) return; const operationSeed = crypto.randomUUID(); const enteredDate = todayIso(); setPendingEntry({ schedule, occurrenceDate: schedule.date_next, enteredDate, operationSeed, idempotencyKey: materializationKey(schedule.id, schedule.date_next, enteredDate, operationSeed) }); setMutationError(null); setMutationSuccess(null); }} onDelete={() => { setPendingDeletion({ schedule, idempotencyKey: mutationKey(`delete-${schedule.id}`) }); setMutationError(null); setMutationSuccess(null); }} />)}</tbody>
            </table>
          </div>
        </section>
      ))}
    </>
  );
}

function ScheduleRows({ schedule, accounts, categories, payees, busy, onEdit, onEnter, onDelete }: { schedule: ScheduledTransaction; accounts: Map<string, string>; categories: Map<string, string>; payees: Map<string, string>; busy: boolean; onEdit: () => void; onEnter: () => void; onDelete: () => void }) {
  const account = nameFor(schedule.account_name, schedule.account_id, accounts, "Account unavailable");
  const payee = scheduleLabel(schedule, payees, accounts);
  const category = categoryLabel(schedule, accounts, categories);
  const amount = amountFor(schedule);
  const detail = [account, category, scheduleRecurrence(schedule.frequency)].filter(Boolean).join(" · ");
  return <>
    <tr className="schedule-row"><td className="schedule-date">{schedule.date_next ? formatDate(schedule.date_next) : "Date unavailable"}</td><td><div className="schedule-payee">{payee}<FlagTag colour={schedule.flag_color} /></div>{schedule.memo && <div className="schedule-memo">{schedule.memo}</div>}<div className="schedule-mobile-detail">{detail}</div></td><td>{account}</td><td>{category}</td><td>{scheduleRecurrence(schedule.frequency)}</td><td className={amount < 0 ? "num amount-negative" : amount > 0 ? "num amount-positive" : "num"}>{formatMoney(amount, { sign: amount > 0 })}</td><td className="register-actions"><button type="button" className="register-row-action" onClick={onEnter} disabled={busy || !schedule.date_next} aria-label={`Enter ${payee} now`}>Enter now</button><button type="button" className="register-row-action" onClick={onEdit} disabled={busy} aria-label={`Edit ${payee}`}>Edit</button><button type="button" className="register-row-action register-row-action-danger" onClick={onDelete} disabled={busy} aria-label={`Delete ${payee}`}>Delete</button></td></tr>
    {(schedule.subtransactions ?? []).map((line) => <SplitScheduleRow key={line.id} line={line} accounts={accounts} categories={categories} payees={payees} />)}
  </>;
}

function SplitScheduleRow({ line, accounts, categories, payees }: { line: ScheduledSubtransaction; accounts: Map<string, string>; categories: Map<string, string>; payees: Map<string, string> }) {
  const payee = nameFor(line.payee_name, line.payee_id, payees, line.transfer_account_id ? transferName(line.transfer_account_id, accounts) : "Split line");
  const category = line.transfer_account_id ? transferName(line.transfer_account_id, accounts) : nameFor(line.category_name, line.category_id, categories, "Uncategorised");
  return <tr className="split-line-row schedule-split-row"><td aria-hidden="true" /><td className="split-line-cell"><span className="schedule-split-mark">Split</span> {payee}{line.memo ? ` · ${line.memo}` : ""}<div className="schedule-mobile-detail">{category}</div></td><td aria-hidden="true" /><td>{category}</td><td aria-hidden="true" /><td className={line.amount < 0 ? "num amount-negative" : line.amount > 0 ? "num amount-positive" : "num"}>{formatMoney(line.amount, { sign: line.amount > 0 })}</td><td aria-hidden="true" /></tr>;
}

function ScheduleEditor({ schedule, accounts, categoryGroups, payees, saving, onCancel, onSave }: { schedule?: ScheduledTransaction; accounts: Account[]; categoryGroups: CategoryGroup[]; payees: Payee[]; saving: boolean; onCancel: () => void; onSave: (input: ScheduledTransactionInput, idempotencyKey: string) => Promise<void> }) {
  const [accountId, setAccountId] = useState(schedule?.account_id ?? accounts.find((account) => !account.closed)?.id ?? "");
  const [firstDate, setFirstDate] = useState(schedule?.date_first ?? schedule?.date_next ?? todayIso());
  const [nextDate, setNextDate] = useState(schedule?.date_next ?? schedule?.date_first ?? todayIso());
  const [frequency, setFrequency] = useState(schedule?.frequency ?? "monthly");
  const [amount, setAmount] = useState(formatMilliunitsInput(amountFor(schedule ?? {} as ScheduledTransaction)));
  const [payeeId, setPayeeId] = useState(schedule?.payee_id ?? "");
  const [categoryId, setCategoryId] = useState(schedule?.category_id ?? "");
  const [transferAccountId, setTransferAccountId] = useState(schedule?.transfer_account_id ?? "");
  const [memo, setMemo] = useState(schedule?.memo ?? "");
  const [flagColor, setFlagColor] = useState(schedule?.flag_color ?? "");
  const [splitLines, setSplitLines] = useState<SplitDraft[]>(() => (schedule?.subtransactions ?? []).map((line) => ({ key: line.id, sourceId: line.id, amount: formatMilliunitsInput(line.amount), payeeId: line.payee_id ?? "", categoryId: line.category_id ?? "", transferAccountId: line.transfer_account_id ?? "", memo: line.memo ?? "" })));
  const [validationError, setValidationError] = useState<string | null>(null);
  const [operationSeed] = useState(() => crypto.randomUUID());
  const groups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const isSplit = splitLines.length >= 2;
  const splitTotal = splitLines.reduce((sum, line) => sum + (parseMilliunits(line.amount) ?? 0), 0);

  const setSplit = (key: string, patch: Partial<SplitDraft>) => setSplitLines((lines) => lines.map((line) => line.key === key ? { ...line, ...patch } : line));
  const setTransfer = (value: string) => { setTransferAccountId(value); if (value) { setPayeeId(""); setCategoryId(""); } };
  const toggleSplit = () => {
    if (isSplit) { setSplitLines([]); return; }
    setTransferAccountId("");
    setCategoryId("");
    setSplitLines([{ key: draftKey(), amount, payeeId, categoryId: "", transferAccountId: "", memo: "" }, { key: draftKey(), amount: "0", payeeId: "", categoryId: "", transferAccountId: "", memo: "" }]);
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    const parsedAmount = isSplit ? splitTotal : parseMilliunits(amount);
    if (!accountId) { setValidationError("Choose the account this schedule uses."); return; }
    if (nextDate < firstDate) { setValidationError("Next date cannot be earlier than the first date."); return; }
    if (parsedAmount === null) { setValidationError("Enter an amount with no more than three decimal places."); return; }
    if (isSplit && splitLines.some((line) => parseMilliunits(line.amount) === null)) { setValidationError("Every split line needs a valid signed amount."); return; }
    const input: ScheduledTransactionInput = { account_id: accountId, date_first: firstDate, date_next: nextDate || null, frequency, amount: parsedAmount, memo: memo.trim() || null, flag_color: flagColor || null };
    if (isSplit) {
      input.category_id = null;
      input.subtransactions = splitLines.map((line) => ({ ...(line.sourceId ? { id: line.sourceId } : {}), amount: parseMilliunits(line.amount)!, payee_id: line.payeeId || null, category_id: line.transferAccountId ? null : line.categoryId || null, transfer_account_id: line.transferAccountId || null, memo: line.memo.trim() || null }));
    } else if (transferAccountId) {
      input.payee_id = null; input.category_id = null; input.transfer_account_id = transferAccountId;
    } else {
      input.payee_id = payeeId || null; input.category_id = categoryId || null; input.transfer_account_id = null;
    }
    setValidationError(null);
    await onSave(input, `scheduled-${operationSeed}-${stableHash(JSON.stringify(input))}`);
  };

  return <section className="transaction-editor schedule-editor" aria-labelledby="schedule-editor-heading">
    <div className="section-heading"><div><span className="section-title" id="schedule-editor-heading">{schedule ? "Edit scheduled transaction" : "Add scheduled transaction"}</span><span className="section-meta">{schedule ? "Changes apply to future instances in HowMuch." : "Create a repeating future ledger entry."}</span></div><button type="button" className="text-button" onClick={onCancel} disabled={saving}>Cancel</button></div>
    <form className="transaction-editor-form" onSubmit={(event) => void submit(event)}>
      <div className="field-row transaction-editor-top-row"><label className="field"><span className="field-label">Account</span><select value={accountId} onChange={(event) => setAccountId(event.target.value)} required><option value="">Choose account</option>{accounts.map((account) => <option key={account.id} value={account.id}>{account.name}{account.closed ? " (closed)" : ""}</option>)}</select></label><label className="field"><span className="field-label">Amount</span><input type="text" inputMode="decimal" value={isSplit ? formatMilliunitsInput(splitTotal) : amount} onChange={(event) => setAmount(event.target.value)} disabled={isSplit} required /><span className="field-note">Use a minus sign for outflow. Amounts use up to three decimal places.</span></label></div>
      <div className="field-row transaction-editor-top-row"><label className="field"><span className="field-label">First date</span><input type="date" value={firstDate} onChange={(event) => setFirstDate(event.target.value)} required /></label><label className="field"><span className="field-label">Next date</span><input type="date" value={nextDate} onChange={(event) => setNextDate(event.target.value)} required /></label><label className="field"><span className="field-label">Repeat</span><select value={frequency} onChange={(event) => setFrequency(event.target.value)}>{FREQUENCIES.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label></div>
      {!isSplit && <><label className="field"><span className="field-label">Transfer</span><select value={transferAccountId} onChange={(event) => setTransfer(event.target.value)}><option value="">Not a transfer</option>{accounts.filter((account) => account.id !== accountId).map((account) => <option key={account.id} value={account.id}>Transfer to {account.name}</option>)}</select></label>{!transferAccountId && <><label className="field"><span className="field-label">Payee</span><select value={payeeId} onChange={(event) => setPayeeId(event.target.value)}><option value="">No payee</option>{payees.filter((payee) => !payee.deleted && !payee.transfer_account_id).map((payee) => <option key={payee.id} value={payee.id}>{payee.name}</option>)}</select></label><label className="field"><span className="field-label">Category</span><CategorySelect value={categoryId} onChange={setCategoryId} groups={groups} /></label></>}</>}
      <label className="transaction-editor-checkbox"><input type="checkbox" checked={isSplit} onChange={toggleSplit} /> Split this schedule</label>
      {isSplit && <fieldset className="transaction-editor-splits"><legend>Split lines</legend><p className="split-remainder split-remainder-ok">The schedule total is {formatMoney(splitTotal, { sign: splitTotal > 0 })}.</p>{splitLines.map((line, index) => <div key={line.key} className="transaction-editor-split-line"><label><span className="sr-only">Split line {index + 1} amount</span><input type="text" inputMode="decimal" value={line.amount} onChange={(event) => setSplit(line.key, { amount: event.target.value })} /></label><label><span className="sr-only">Split line {index + 1} transfer</span><select value={line.transferAccountId} onChange={(event) => setSplit(line.key, { transferAccountId: event.target.value, ...(event.target.value ? { categoryId: "", payeeId: "" } : {}) })}><option value="">Not a transfer</option>{accounts.filter((account) => account.id !== accountId).map((account) => <option key={account.id} value={account.id}>To {account.name}</option>)}</select></label>{!line.transferAccountId && <><label><span className="sr-only">Split line {index + 1} payee</span><select value={line.payeeId} onChange={(event) => setSplit(line.key, { payeeId: event.target.value })}><option value="">No payee</option>{payees.filter((payee) => !payee.deleted && !payee.transfer_account_id).map((payee) => <option key={payee.id} value={payee.id}>{payee.name}</option>)}</select></label><label><span className="sr-only">Split line {index + 1} category</span><CategorySelect value={line.categoryId} onChange={(value) => setSplit(line.key, { categoryId: value })} groups={groups} /></label></>}<label><span className="sr-only">Split line {index + 1} memo</span><input value={line.memo} onChange={(event) => setSplit(line.key, { memo: event.target.value })} placeholder="Line memo" /></label>{splitLines.length > 2 && <button type="button" className="text-button" onClick={() => setSplitLines((lines) => lines.filter((item) => item.key !== line.key))}>Remove</button>}</div>)}<button type="button" className="text-button" onClick={() => setSplitLines((lines) => [...lines, { key: draftKey(), amount: "0", payeeId: "", categoryId: "", transferAccountId: "", memo: "" }])}>Add split line</button></fieldset>}
      <label className="field"><span className="field-label">Memo</span><input value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="Note" /></label>
      <div className="field"><span className="field-label" id="schedule-flag-label">Flag</span><FlagPicker labelledBy="schedule-flag-label" value={flagColor} onChange={setFlagColor} disabled={saving} /></div>
      {validationError && <p className="transaction-editor-error" role="alert">{validationError}</p>}
      <div className="transaction-editor-actions"><button type="button" className="text-button" onClick={onCancel} disabled={saving}>Cancel</button><button type="submit" className="save-button" disabled={saving}>{saving ? "Saving…" : schedule ? "Save changes" : "Add schedule"}</button></div>
    </form>
  </section>;
}

function Figure({ label, value }: { label: string; value: string }) { return <div className="headline-figure"><span className="figure-label">{label}</span><span className="figure-value schedule-figure-value">{value}</span></div>; }
function groupSchedules(schedules: ScheduledTransaction[]): ScheduleGroup[] { const groups = new Map<string, ScheduledTransaction[]>(); for (const schedule of schedules) { const date = schedule.date_next ?? schedule.date_first ?? "Date unavailable"; const entries = groups.get(date) ?? []; entries.push(schedule); groups.set(date, entries); } return [...groups.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([date, entries]) => ({ date, schedules: entries })); }
function compareSchedules(left: ScheduledTransaction, right: ScheduledTransaction): number { return (left.date_next ?? left.date_first ?? "9999-12-31").localeCompare(right.date_next ?? right.date_first ?? "9999-12-31") || left.id.localeCompare(right.id); }
function amountFor(schedule: ScheduledTransaction): number { if (Number.isSafeInteger(schedule.amount)) return Number(schedule.amount); return (schedule.subtransactions ?? []).reduce((sum, line) => sum + (Number.isSafeInteger(line.amount) ? line.amount : 0), 0); }
function nameFor(name: string | null | undefined, id: string | null | undefined, names: Map<string, string>, fallback: string): string { return name ?? (id ? names.get(id) ?? fallback : fallback); }
function scheduleLabel(schedule: ScheduledTransaction, payees: Map<string, string>, accounts: Map<string, string>): string { return nameFor(schedule.payee_name, schedule.payee_id, payees, schedule.transfer_account_id ? transferName(schedule.transfer_account_id, accounts) : "No payee"); }
function transferName(accountId: string, accounts: Map<string, string>): string { return `Transfer to ${accounts.get(accountId) ?? "account"}`; }
function categoryLabel(schedule: ScheduledTransaction, accounts: Map<string, string>, categories: Map<string, string>): string { if (schedule.transfer_account_id) return transferName(schedule.transfer_account_id, accounts); return nameFor(schedule.category_name, schedule.category_id, categories, "Uncategorised"); }
function draftKey(): string { return `split-${crypto.randomUUID()}`; }
function mutationKey(action: string): string { return `scheduled-${action}-${crypto.randomUUID()}`; }
function materializationKey(scheduleId: string, occurrenceDate: string, enteredDate: string, seed: string): string { return `scheduled-enter-${seed}-${stableHash(`${scheduleId}:${occurrenceDate}:${enteredDate}`)}`; }
const FREQUENCIES: Array<[string, string]> = [["never", "Once"], ["daily", "Daily"], ["weekly", "Weekly"], ["everyOtherWeek", "Every other week"], ["every4Weeks", "Every 4 weeks"], ["monthly", "Monthly"], ["everyOtherMonth", "Every other month"], ["every3Months", "Every 3 months"], ["every4Months", "Every 4 months"], ["twiceAMonth", "Twice a month"], ["yearly", "Yearly"], ["everyOtherYear", "Every other year"], ["twiceAYear", "Twice a year"]];
