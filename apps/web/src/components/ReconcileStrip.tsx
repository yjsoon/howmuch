import { useState } from "react";
import { api } from "../api/client";
import type { Account } from "../api/types";
import { todayIso } from "../lib/dates";
import { decimalToMilli, formatMoney } from "../lib/money";

/**
 * YNAB-style reconcile: confirm the real-world balance and post a reconciled
 * "Balance Adjustment" for any difference.
 */
export function ReconcileStrip({
  planId,
  account,
  onDone,
  onCancel,
}: {
  planId: string;
  account: Account;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [actualBalance, setActualBalance] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const parsed = (() => {
    try {
      return actualBalance.trim() === "" ? null : decimalToMilli(actualBalance);
    } catch {
      return null;
    }
  })();
  const difference = parsed === null ? null : parsed - account.balance;

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (difference === null) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (difference !== 0) {
        await api.createTransaction(planId, {
          account_id: account.id,
          date: todayIso(),
          amount: difference,
          payee_name: "Manual Balance Adjustment",
          memo: "Reconciled via web",
          cleared: "reconciled",
          approved: true,
        });
      }
      onDone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  return (
    <form className="inline-form confirm-strip reconcile-strip" onSubmit={submit}>
      <span className="muted">
        {account.name}: ledger shows {formatMoney(account.balance)}. Actual balance:
      </span>
      <input
        type="number"
        step="0.01"
        value={actualBalance}
        onChange={(event) => setActualBalance(event.target.value)}
        placeholder="0.00"
        autoFocus
        required
      />
      {difference !== null && (
        <span className={difference === 0 ? "muted" : difference > 0 ? "amount-positive" : "amount-negative"}>
          {difference === 0 ? "Already matches" : `Adjustment ${formatMoney(difference, { sign: true })}`}
        </span>
      )}
      {error && <span className="amount-negative">{error}</span>}
      <button type="submit" disabled={busy || parsed === null}>
        {difference === 0 ? "Finish reconcile" : "Post adjustment"}
      </button>
      <button type="button" className="text-button" onClick={onCancel}>
        Cancel
      </button>
    </form>
  );
}
