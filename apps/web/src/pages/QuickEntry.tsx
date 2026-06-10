import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { Transaction } from "../api/types";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate, todayIso, yesterdayIso } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { usePlan } from "../state/plan";

type Direction = "spend" | "income";

export function QuickEntryPage() {
  const { planId, accounts, categoryGroups } = usePlan();
  const payees = useApi(planId, () => api.payees(planId));

  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);

  const [direction, setDirection] = useState<Direction>("spend");
  const [amount, setAmount] = useState("");
  const [accountId, setAccountId] = useState("");
  const [payeeName, setPayeeName] = useState("");
  const [categoryId, setCategoryId] = useState("");
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

  const selectedAccount = accountId || openAccounts[0]?.id || "";
  const selectedAccountName =
    openAccounts.find((account) => account.id === selectedAccount)?.name ?? "No open account";
  const canSave = Boolean(selectedAccount && payeeName.trim() && Number(amount) > 0 && !saving);

  const clearStatus = () => {
    setError(null);
    setSaved(null);
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!canSave) {
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const transaction = await api.quickEntry({
        client_id: clientIdRef.current,
        account_id: selectedAccount,
        date,
        amount: direction === "spend" ? `-${amount}` : amount,
        payee_name: payeeName.trim(),
        category_id: categoryId || null,
        memo: memo.trim() || null,
        flag_color: null,
      });
      setSaved(`${transaction.payee_name ?? "Entry"} saved.`);
      setRecent((entries) => [transaction, ...entries].slice(0, 5));
      setAmount("");
      setPayeeName("");
      setMemo("");
      setCategoryId("");
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
              onClick={() => {
                clearStatus();
                setDirection("spend");
              }}
            >
              Spend
            </button>
            <button
              type="button"
              className={direction === "income" ? "segment segment-active" : "segment"}
              onClick={() => {
                clearStatus();
                setDirection("income");
              }}
            >
              Income
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
              {direction === "spend" ? "Saved as an outflow in the ledger." : "Saved as an inflow in the ledger."}
            </span>
          </label>

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
                .filter((payee) => !payee.deleted)
                .map((payee) => (
                  <option key={payee.id} value={payee.name} />
                ))}
            </datalist>
          </label>

          <label className="field">
            <span className="field-label">Account</span>
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
            {saving ? "Saving..." : direction === "spend" ? "Save spend" : "Save income"}
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
