import { useMemo, useState } from "react";
import { api } from "../api/client";
import type { Account } from "../api/types";
import { todayIso } from "../lib/dates";
import { decimalToMilli, formatMoney } from "../lib/money";
import { usePlan } from "../state/plan";

const ACCOUNT_TYPES: Array<{ value: string; label: string }> = [
  { value: "checking", label: "Checking" },
  { value: "savings", label: "Savings" },
  { value: "cash", label: "Cash" },
  { value: "creditCard", label: "Credit card" },
  { value: "lineOfCredit", label: "Line of credit" },
  { value: "otherAsset", label: "Other asset" },
  { value: "otherLiability", label: "Other liability" },
];

function typeLabel(type: string | null): string {
  return ACCOUNT_TYPES.find((entry) => entry.value === type)?.label ?? (type || "Other");
}

export function AccountsPage() {
  const { planId, accounts, reload } = usePlan();
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const open = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const closed = useMemo(() => accounts.filter((account) => account.closed), [accounts]);
  const netTotal = useMemo(() => open.reduce((total, account) => total + account.balance, 0), [open]);

  const run = async (accountId: string, action: () => Promise<unknown>) => {
    setBusyId(accountId);
    setError(null);
    try {
      await action();
      reload();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusyId(null);
    }
  };

  return (
    <>
      <div className="report-header">
        <h1>Accounts</h1>
        <div className="headline-row">
          <div className="headline-figure">
            <span className="figure-label">{open.length} open accounts · total</span>
            <span className={netTotal >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {formatMoney(netTotal)}
            </span>
          </div>
        </div>
      </div>

      {error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">That change did not save.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}

      <section className="report-section">
        <div className="section-heading">
          <span className="section-title">Open accounts</span>
          <span className="section-meta">Rename, reconcile, or close</span>
        </div>
        {open.length ? (
          <div className="table-wrap table-wrap-wide">
            <table className="ledger-table register-table">
              <thead>
                <tr>
                  <th>Account</th>
                  <th>Type</th>
                  <th className="num">Cleared</th>
                  <th className="num">Uncleared</th>
                  <th className="num">Working balance</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {open.map((account) => (
                  <AccountRow
                    key={account.id}
                    account={account}
                    planId={planId}
                    busy={busyId === account.id}
                    onAction={(action) => run(account.id, action)}
                  />
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="status-panel">
            <p className="status-title">No open accounts.</p>
            <p className="status-detail">Create one below to start recording transactions.</p>
          </div>
        )}
      </section>

      {closed.length > 0 && (
        <section className="report-section">
          <div className="section-heading">
            <span className="section-title">Closed accounts</span>
            <span className="section-meta">Kept for history and net-worth reports</span>
          </div>
          <div className="table-wrap">
            <table className="ledger-table">
              <thead>
                <tr>
                  <th>Account</th>
                  <th>Type</th>
                  <th className="num">Balance</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {closed.map((account) => (
                  <tr key={account.id}>
                    <td>{account.name}</td>
                    <td className="muted">{typeLabel(account.type)}</td>
                    <td className="num">{formatMoney(account.balance)}</td>
                    <td>
                      <button
                        type="button"
                        className="text-button"
                        disabled={busyId === account.id}
                        onClick={() => run(account.id, () => api.updateAccount(planId, account.id, { closed: false }))}
                      >
                        Reopen
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <NewAccountForm planId={planId} onCreated={reload} />
    </>
  );
}

function AccountRow({
  account,
  planId,
  busy,
  onAction,
}: {
  account: Account;
  planId: string;
  busy: boolean;
  onAction: (action: () => Promise<unknown>) => void;
}) {
  const [mode, setMode] = useState<"view" | "rename" | "reconcile">("view");
  const [name, setName] = useState(account.name);
  const [actualBalance, setActualBalance] = useState("");

  if (mode === "rename") {
    return (
      <tr>
        <td colSpan={6}>
          <form
            className="inline-form"
            onSubmit={(event) => {
              event.preventDefault();
              onAction(() => api.updateAccount(planId, account.id, { name: name.trim() }));
              setMode("view");
            }}
          >
            <input value={name} onChange={(event) => setName(event.target.value)} autoFocus required />
            <button type="submit" disabled={busy || !name.trim()}>
              Save
            </button>
            <button type="button" className="text-button" onClick={() => setMode("view")}>
              Cancel
            </button>
          </form>
        </td>
      </tr>
    );
  }

  if (mode === "reconcile") {
    const parsed = (() => {
      try {
        return actualBalance.trim() === "" ? null : decimalToMilli(actualBalance);
      } catch {
        return null;
      }
    })();
    const difference = parsed === null ? null : parsed - account.balance;
    return (
      <tr>
        <td colSpan={6}>
          <form
            className="inline-form"
            onSubmit={(event) => {
              event.preventDefault();
              if (difference === null) {
                return;
              }
              onAction(async () => {
                if (difference !== 0) {
                  await api.createTransaction(planId, {
                    account_id: account.id,
                    date: todayIso(),
                    amount: difference,
                    payee_name: "Balance Adjustment",
                    memo: "Reconciled via web",
                    cleared: "reconciled",
                    approved: true,
                  });
                }
              });
              setMode("view");
              setActualBalance("");
            }}
          >
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
            <button type="submit" disabled={busy || parsed === null}>
              {difference === 0 ? "Done" : "Post adjustment"}
            </button>
            <button type="button" className="text-button" onClick={() => setMode("view")}>
              Cancel
            </button>
          </form>
        </td>
      </tr>
    );
  }

  return (
    <tr>
      <td className="strong">{account.name}</td>
      <td className="muted">{typeLabel(account.type)}</td>
      <td className="num">{formatMoney(account.cleared_balance)}</td>
      <td className="num">{formatMoney(account.uncleared_balance)}</td>
      <td className={account.balance < 0 ? "num amount-negative" : "num amount-positive"}>
        {formatMoney(account.balance)}
      </td>
      <td className="nowrap">
        <button type="button" className="text-button" disabled={busy} onClick={() => setMode("rename")}>
          Rename
        </button>
        <button type="button" className="text-button" disabled={busy} onClick={() => setMode("reconcile")}>
          Reconcile
        </button>
        <button
          type="button"
          className="text-button"
          disabled={busy}
          onClick={() => onAction(() => api.updateAccount(planId, account.id, { closed: true }))}
        >
          Close
        </button>
      </td>
    </tr>
  );
}

function NewAccountForm({ planId, onCreated }: { planId: string; onCreated: () => void }) {
  const [name, setName] = useState("");
  const [type, setType] = useState("checking");
  const [balance, setBalance] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await api.createAccount(planId, {
        name: name.trim(),
        type,
        opening_balance: decimalToMilli(balance || "0"),
      });
      setName("");
      setBalance("");
      onCreated();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="report-section">
      <div className="section-heading">
        <span className="section-title">Add account</span>
        <span className="section-meta">Starting balance posts as the opening balance</span>
      </div>
      <form onSubmit={submit} className="inline-form manage-form">
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder="Account name"
          aria-label="Account name"
          required
        />
        <select value={type} onChange={(event) => setType(event.target.value)} aria-label="Account type">
          {ACCOUNT_TYPES.map((entry) => (
            <option key={entry.value} value={entry.value}>
              {entry.label}
            </option>
          ))}
        </select>
        <input
          type="number"
          step="0.01"
          value={balance}
          onChange={(event) => setBalance(event.target.value)}
          placeholder="Starting balance"
          aria-label="Starting balance"
        />
        <button type="submit" disabled={busy || !name.trim()}>
          {busy ? "Adding…" : "Add account"}
        </button>
      </form>
      {error && (
        <div className="status-panel status-panel-error compact-panel">
          <p className="status-title">Could not add the account.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}
    </section>
  );
}
