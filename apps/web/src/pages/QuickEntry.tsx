import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { QuickEntrySplitLine, Transaction } from "../api/types";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate, todayIso, yesterdayIso } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { usePlan } from "../state/plan";

type Direction = "spend" | "income" | "transfer";

type SplitLineDraft = {
  key: string;
  categoryId: string;
  amount: string;
  memo: string;
};

function newSplitLine(): SplitLineDraft {
  return { key: crypto.randomUUID(), categoryId: "", amount: "", memo: "" };
}

/** Whole cents, so split remainders never suffer float drift. */
function toCents(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.round(parsed * 100) : 0;
}

export function QuickEntryPage() {
  const { planId, accounts, categoryGroups } = usePlan();
  const payees = useApi(planId, () => api.payees(planId));

  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);

  const [direction, setDirection] = useState<Direction>("spend");
  const [amount, setAmount] = useState("");
  const [accountId, setAccountId] = useState("");
  const [toAccountId, setToAccountId] = useState("");
  const [payeeName, setPayeeName] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [isSplit, setIsSplit] = useState(false);
  const [splitLines, setSplitLines] = useState<SplitLineDraft[]>([]);
  const [memo, setMemo] = useState("");
  const [date, setDate] = useState(todayIso());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [recent, setRecent] = useState<Transaction[]>([]);
  // Generated per entry attempt so retries of a failed submit stay idempotent.
  const clientIdRef = useRef(crypto.randomUUID());
  const amountRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    document.title = "Quick entry · HowMuch";
  }, []);

  const isTransfer = direction === "transfer";
  const selectedAccount = accountId || openAccounts[0]?.id || "";
  const selectedAccountName =
    openAccounts.find((account) => account.id === selectedAccount)?.name ?? "No open account";
  const transferTargets = useMemo(
    () => openAccounts.filter((account) => account.id !== selectedAccount && account.transfer_payee_id),
    [openAccounts, selectedAccount],
  );
  const selectedTarget = transferTargets.find((account) => account.id === toAccountId) ?? transferTargets[0];

  const amountCents = toCents(amount);
  const splitRemainderCents = isSplit
    ? amountCents - splitLines.reduce((sum, line) => sum + toCents(line.amount), 0)
    : 0;

  const canSave = Boolean(
    selectedAccount &&
      Number(amount) > 0 &&
      !saving &&
      (isTransfer
        ? Boolean(selectedTarget)
        : Boolean(payeeName.trim()) &&
          (!isSplit ||
            (splitLines.length >= 2 &&
              splitRemainderCents === 0 &&
              splitLines.every((line) => toCents(line.amount) > 0)))),
  );

  const clearStatus = () => {
    setError(null);
    setSaved(null);
  };

  const switchDirection = (next: Direction) => {
    clearStatus();
    setDirection(next);
    if (next === "transfer") {
      setIsSplit(false);
    }
  };

  const toggleSplit = () => {
    clearStatus();
    setIsSplit((current) => {
      if (!current) {
        setSplitLines((lines) => (lines.length >= 2 ? lines : [newSplitLine(), newSplitLine()]));
        setCategoryId("");
      }
      return !current;
    });
  };

  const updateSplitLine = (key: string, patch: Partial<SplitLineDraft>) => {
    clearStatus();
    setSplitLines((lines) => lines.map((line) => (line.key === key ? { ...line, ...patch } : line)));
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!canSave) {
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const sign = direction === "income" ? "" : "-";
      const subtransactions: QuickEntrySplitLine[] | undefined =
        !isTransfer && isSplit
          ? splitLines.map((line) => ({
              amount: `${sign}${line.amount}`,
              category_id: line.categoryId || null,
              memo: line.memo.trim() || null,
            }))
          : undefined;
      const transaction = await api.quickEntry({
        client_id: clientIdRef.current,
        account_id: selectedAccount,
        date,
        amount: `${sign}${amount}`,
        payee_id: isTransfer ? (selectedTarget?.transfer_payee_id ?? null) : null,
        payee_name: isTransfer ? null : payeeName.trim(),
        category_id: isTransfer || isSplit ? null : categoryId || null,
        memo: memo.trim() || null,
        flag_color: null,
        subtransactions,
      });
      setSaved(
        isTransfer
          ? `Transfer to ${selectedTarget?.name ?? "account"} saved.`
          : `${transaction.payee_name ?? "Entry"} saved.`,
      );
      setRecent((entries) => [transaction, ...entries].slice(0, 5));
      setAmount("");
      setPayeeName("");
      setMemo("");
      setCategoryId("");
      setIsSplit(false);
      setSplitLines([]);
      clientIdRef.current = crypto.randomUUID();
      amountRef.current?.focus();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="quick-entry">
      <header className="quick-entry-head">
        <Link to="/spending" className="back-link">
          ‹ Reports
        </Link>
        <span className="quick-entry-title">Quick entry</span>
      </header>

      <div className="quick-entry-meta">
        <div>
          <span className="figure-label">Posting account</span>
          <div className="quick-entry-meta-value">{selectedAccountName}</div>
        </div>
        <div>
          <span className="figure-label">Posting date</span>
          <div className="quick-entry-meta-value">{date}</div>
        </div>
      </div>

      {!openAccounts.length ? (
        <div className="status-panel status-panel-error">
          <p className="status-title">No open accounts available.</p>
          <p className="status-detail">Create or import an account before using quick entry.</p>
        </div>
      ) : (
        <form onSubmit={submit} className="quick-entry-form">
          <div className="segmented direction-toggle" role="group" aria-label="Direction">
            <button
              type="button"
              className={direction === "spend" ? "segment segment-active" : "segment"}
              onClick={() => switchDirection("spend")}
            >
              Spend
            </button>
            <button
              type="button"
              className={direction === "income" ? "segment segment-active" : "segment"}
              onClick={() => switchDirection("income")}
            >
              Income
            </button>
            <button
              type="button"
              className={direction === "transfer" ? "segment segment-active" : "segment"}
              onClick={() => switchDirection("transfer")}
            >
              Transfer
            </button>
          </div>

          <label className="field amount-field">
            <span className="field-label">Amount</span>
            <input
              type="number"
              name="amount"
              inputMode="decimal"
              step="0.01"
              min="0"
              placeholder="0.00"
              value={amount}
              onChange={(event) => {
                clearStatus();
                setAmount(event.target.value);
              }}
              className={direction === "spend" ? "amount-input amount-input-spend" : "amount-input amount-input-income"}
              ref={amountRef}
              autoFocus
              required
            />
            <span className="field-note">
              {direction === "spend"
                ? "Saved as an outflow in the ledger."
                : direction === "income"
                  ? "Saved as an inflow in the ledger."
                  : "Moves money between two accounts; both sides are recorded."}
            </span>
          </label>

          {!isTransfer && (
            <label className="field">
              <span className="field-label">Payee</span>
              <input
                type="text"
                name="payee"
                list="payee-options"
                value={payeeName}
                onChange={(event) => {
                  clearStatus();
                  setPayeeName(event.target.value);
                }}
                placeholder="Merchant"
                required
                autoComplete="off"
              />
              <datalist id="payee-options">
                {(payees.data ?? [])
                  .filter((payee) => !payee.deleted && !payee.transfer_account_id)
                  .map((payee) => (
                    <option key={payee.id} value={payee.name} />
                  ))}
              </datalist>
            </label>
          )}

          <label className="field">
            <span className="field-label">{isTransfer ? "From account" : "Account"}</span>
            <select
              name="account"
              value={selectedAccount}
              onChange={(event) => {
                clearStatus();
                setAccountId(event.target.value);
              }}
            >
              {openAccounts.map((account) => (
                <option key={account.id} value={account.id}>
                  {account.name}
                </option>
              ))}
            </select>
          </label>

          {isTransfer && (
            <label className="field">
              <span className="field-label">To account</span>
              {transferTargets.length ? (
                <select
                  name="to-account"
                  value={selectedTarget?.id ?? ""}
                  onChange={(event) => {
                    clearStatus();
                    setToAccountId(event.target.value);
                  }}
                >
                  {transferTargets.map((account) => (
                    <option key={account.id} value={account.id}>
                      {account.name}
                    </option>
                  ))}
                </select>
              ) : (
                <span className="field-note">No other open account to transfer to.</span>
              )}
            </label>
          )}

          {!isTransfer && !isSplit && (
            <label className="field">
              <span className="field-label">Category (optional)</span>
              <select
                name="category"
                value={categoryId}
                onChange={(event) => {
                  clearStatus();
                  setCategoryId(event.target.value);
                }}
              >
                <option value="">Uncategorised</option>
                {[...orderedGroups.primary, ...orderedGroups.quiet].map((group) => (
                  <optgroup key={group.id} label={group.name}>
                    {group.categories.map((category) => (
                      <option key={category.id} value={category.id}>
                        {category.name}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </label>
          )}

          {!isTransfer && (
            <div className="split-controls">
              <button type="button" className="split-toggle" onClick={toggleSplit}>
                {isSplit ? "Remove split" : "Split into multiple categories"}
              </button>
              {isSplit && (
                <span className={splitRemainderCents === 0 ? "split-remainder split-remainder-ok" : "split-remainder"}>
                  {splitRemainderCents === 0
                    ? "Lines match the total."
                    : `${formatMoney(splitRemainderCents * 10, { sign: true })} left to assign.`}
                </span>
              )}
            </div>
          )}

          {!isTransfer && isSplit && (
            <div className="split-lines">
              {splitLines.map((line, index) => (
                <div key={line.key} className="split-line">
                  <select
                    aria-label={`Split line ${index + 1} category`}
                    value={line.categoryId}
                    onChange={(event) => updateSplitLine(line.key, { categoryId: event.target.value })}
                  >
                    <option value="">Uncategorised</option>
                    {[...orderedGroups.primary, ...orderedGroups.quiet].map((group) => (
                      <optgroup key={group.id} label={group.name}>
                        {group.categories.map((category) => (
                          <option key={category.id} value={category.id}>
                            {category.name}
                          </option>
                        ))}
                      </optgroup>
                    ))}
                  </select>
                  <input
                    type="text"
                    placeholder="Line memo"
                    aria-label={`Split line ${index + 1} memo`}
                    value={line.memo}
                    onChange={(event) => updateSplitLine(line.key, { memo: event.target.value })}
                  />
                  <input
                    type="number"
                    inputMode="decimal"
                    step="0.01"
                    min="0"
                    placeholder="0.00"
                    aria-label={`Split line ${index + 1} amount`}
                    value={line.amount}
                    onChange={(event) => updateSplitLine(line.key, { amount: event.target.value })}
                  />
                  <button
                    type="button"
                    className="split-line-remove"
                    aria-label={`Remove split line ${index + 1}`}
                    onClick={() => {
                      clearStatus();
                      setSplitLines((lines) => lines.filter((candidate) => candidate.key !== line.key));
                    }}
                    disabled={splitLines.length <= 2}
                  >
                    ×
                  </button>
                </div>
              ))}
              <button
                type="button"
                className="split-toggle"
                onClick={() => {
                  clearStatus();
                  setSplitLines((lines) => [...lines, newSplitLine()]);
                }}
              >
                Add line
              </button>
            </div>
          )}

          <div className="field-row field-row-compact">
            <label className="field">
              <span className="field-label">Date</span>
              <div className="date-row">
                <input
                  type="date"
                  name="date"
                  value={date}
                  onChange={(event) => {
                    clearStatus();
                    setDate(event.target.value);
                  }}
                />
                <div className="segmented date-presets" role="group" aria-label="Date shortcuts">
                  <button
                    type="button"
                    className={date === todayIso() ? "segment segment-active" : "segment"}
                    onClick={() => {
                      clearStatus();
                      setDate(todayIso());
                    }}
                  >
                    Today
                  </button>
                  <button
                    type="button"
                    className={date === yesterdayIso() ? "segment segment-active" : "segment"}
                    onClick={() => {
                      clearStatus();
                      setDate(yesterdayIso());
                    }}
                  >
                    Yest.
                  </button>
                </div>
              </div>
            </label>
            <label className="field">
              <span className="field-label">Memo (optional)</span>
              <input
                type="text"
                name="memo"
                value={memo}
                onChange={(event) => {
                  clearStatus();
                  setMemo(event.target.value);
                }}
                placeholder="Note"
              />
            </label>
          </div>

          <p className="field-note">
            Entries post straight to the selected account and refresh the reports after the next load.
          </p>

          {error && (
            <div className="status-panel status-panel-error compact-panel">
              <p className="status-title">Could not save this entry.</p>
              <p className="status-detail">{error}</p>
            </div>
          )}
          {saved && !error && (
            <div className="status-panel status-panel-success compact-panel">
              <p className="status-title">Saved.</p>
              <p className="status-detail">{saved}</p>
            </div>
          )}

          <button type="submit" className="save-button" disabled={!canSave}>
            {saving
              ? "Saving..."
              : direction === "spend"
                ? "Save spend"
                : direction === "income"
                  ? "Save income"
                  : "Save transfer"}
          </button>
        </form>
      )}

      {recent.length > 0 && (
        <section className="recent-entries" aria-label="Saved this session">
          <h2 className="recent-heading">Saved this session</h2>
          <ul>
            {recent.map((entry) => (
              <li key={entry.id}>
                <span className="recent-payee">{entry.payee_name ?? "Entry"}</span>
                <span className="recent-meta">{formatDate(entry.date)}</span>
                <span className={entry.amount < 0 ? "recent-amount amount-negative" : "recent-amount amount-positive"}>
                  {formatMoney(entry.amount)}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
