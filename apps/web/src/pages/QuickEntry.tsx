import { useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, useApi } from "../api/client";
import { todayIso } from "../lib/dates";
import { usePlan } from "../state/plan";

type Direction = "spend" | "income";

export function QuickEntryPage() {
  const { planId, accounts, categoryGroups } = usePlan();
  const payees = useApi(planId, () => api.payees(planId));

  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);

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
  // Generated per entry attempt so retries of a failed submit stay idempotent.
  const clientIdRef = useRef(crypto.randomUUID());

  const selectedAccount = accountId || openAccounts[0]?.id || "";
  const canSave = Boolean(selectedAccount && payeeName.trim() && Number(amount) > 0 && !saving);

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
      setAmount("");
      setPayeeName("");
      setMemo("");
      setCategoryId("");
      clientIdRef.current = crypto.randomUUID();
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

      <form onSubmit={submit}>
        <div className="segmented direction-toggle" role="group" aria-label="Direction">
          <button
            type="button"
            className={direction === "spend" ? "segment segment-active" : "segment"}
            onClick={() => setDirection("spend")}
          >
            Spend
          </button>
          <button
            type="button"
            className={direction === "income" ? "segment segment-active" : "segment"}
            onClick={() => setDirection("income")}
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
            onChange={(event) => setAmount(event.target.value)}
            className={direction === "spend" ? "amount-input amount-input-spend" : "amount-input amount-input-income"}
            autoFocus
            required
          />
        </label>

        <label className="field">
          <span className="field-label">Payee</span>
          <input
            type="text"
            name="payee"
            list="payee-options"
            value={payeeName}
            onChange={(event) => setPayeeName(event.target.value)}
            placeholder="Merchant"
            required
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
          <select name="account" value={selectedAccount} onChange={(event) => setAccountId(event.target.value)}>
            {openAccounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.name}
              </option>
            ))}
          </select>
        </label>

        <label className="field">
          <span className="field-label">Category (optional)</span>
          <select name="category" value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
            <option value="">Uncategorised</option>
            {categoryGroups.map((group) => (
              <optgroup key={group.id} label={group.name}>
                {(group.categories ?? [])
                  .filter((category) => !category.deleted)
                  .map((category) => (
                    <option key={category.id} value={category.id}>
                      {category.name}
                    </option>
                  ))}
              </optgroup>
            ))}
          </select>
        </label>

        <div className="field-row">
          <label className="field">
            <span className="field-label">Date</span>
            <input type="date" name="date" value={date} onChange={(event) => setDate(event.target.value)} />
          </label>
          <label className="field">
            <span className="field-label">Memo (optional)</span>
            <input
              type="text"
              name="memo"
              value={memo}
              onChange={(event) => setMemo(event.target.value)}
              placeholder="Note"
            />
          </label>
        </div>

        {error && <p className="error-note">{error}</p>}
        {saved && !error && <p className="saved-note">{saved}</p>}

        <button type="submit" className="save-button" disabled={!canSave}>
          {saving ? "Saving…" : direction === "spend" ? "Save spend" : "Save income"}
        </button>
      </form>
    </div>
  );
}
