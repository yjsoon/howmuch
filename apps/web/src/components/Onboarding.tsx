import { useState } from "react";
import { api } from "../api/client";
import { decimalToMilli } from "../lib/money";

/**
 * Shown when the API is reachable but holds no plans yet: either pull a full
 * history from YNAB or open a first account and start clean.
 */
export function Onboarding({ defaultPlanId, onReady }: { defaultPlanId: string; onReady: () => void }) {
  const [mode, setMode] = useState<"ynab" | "fresh">("ynab");
  return (
    <div className="boot-message onboarding">
      <h1 className="onboarding-title">Welcome to HowMuch</h1>
      <p className="boot-detail">This ledger is empty. Bring your YNAB history across, or start from scratch.</p>
      <div className="segmented" role="group" aria-label="Setup mode">
        <button
          type="button"
          className={mode === "ynab" ? "segment segment-active" : "segment"}
          onClick={() => setMode("ynab")}
        >
          Import from YNAB
        </button>
        <button
          type="button"
          className={mode === "fresh" ? "segment segment-active" : "segment"}
          onClick={() => setMode("fresh")}
        >
          Start fresh
        </button>
      </div>
      {mode === "ynab" ? <YnabImportForm onImported={onReady} /> : <FirstAccountForm planId={defaultPlanId} onCreated={onReady} />}
    </div>
  );
}

/** Token → pick a budget → full-history import. Reused by the Manage page for re-runs. */
export function YnabImportForm({ onImported }: { onImported: (planId: string) => void }) {
  const [token, setToken] = useState("");
  const [plans, setPlans] = useState<Array<{ id: string; name: string }> | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const findPlans = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy("list");
    setError(null);
    try {
      setPlans(await api.listYnabPlans(token.trim()));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  const runImport = async (planId: string, name: string) => {
    setBusy(planId);
    setError(null);
    try {
      const result = await api.importYnab(planId, token.trim());
      setDone(`Imported ${result.imported_transactions ?? "all"} transactions from “${name}”.`);
      onImported(planId);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="import-form">
      <form onSubmit={findPlans} className="token-form">
        <input
          type="password"
          value={token}
          onChange={(event) => setToken(event.target.value)}
          placeholder="YNAB personal access token"
          aria-label="YNAB personal access token"
          required
        />
        <button type="submit" disabled={!token.trim() || busy === "list"}>
          {busy === "list" ? "Checking…" : "Find budgets"}
        </button>
      </form>
      <p className="field-note">
        Create a token under YNAB → Account settings → Developers. The token goes to your HowMuch server only, never
        to a third party. Importing runs on the server and can take a minute for a long history.
      </p>
      {plans && plans.length === 0 && <p className="boot-detail">No budgets are visible to this token.</p>}
      {plans && plans.length > 0 && (
        <ul className="plan-list">
          {plans.map((plan) => (
            <li key={plan.id}>
              <span className="strong">{plan.name}</span>
              <button type="button" disabled={busy !== null} onClick={() => runImport(plan.id, plan.name)}>
                {busy === plan.id ? "Importing…" : "Import"}
              </button>
            </li>
          ))}
        </ul>
      )}
      {error && (
        <div className="status-panel status-panel-error compact-panel">
          <p className="status-title">Import failed.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}
      {done && !error && (
        <div className="status-panel status-panel-success compact-panel">
          <p className="status-title">{done}</p>
        </div>
      )}
    </div>
  );
}

function FirstAccountForm({ planId, onCreated }: { planId: string; onCreated: () => void }) {
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
      onCreated();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="import-form onboarding-account">
      <label className="field">
        <span className="field-label">First account name</span>
        <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Everyday checking" required />
      </label>
      <label className="field">
        <span className="field-label">Type</span>
        <select value={type} onChange={(event) => setType(event.target.value)}>
          <option value="checking">Checking</option>
          <option value="savings">Savings</option>
          <option value="cash">Cash</option>
          <option value="creditCard">Credit card</option>
          <option value="otherAsset">Other asset</option>
          <option value="otherLiability">Other liability</option>
        </select>
      </label>
      <label className="field">
        <span className="field-label">Current balance</span>
        <input
          type="number"
          step="0.01"
          value={balance}
          onChange={(event) => setBalance(event.target.value)}
          placeholder="0.00"
        />
      </label>
      {error && (
        <div className="status-panel status-panel-error compact-panel">
          <p className="status-title">Could not create the account.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}
      <button type="submit" className="save-button" disabled={busy || !name.trim()}>
        {busy ? "Creating…" : "Create ledger"}
      </button>
    </form>
  );
}
