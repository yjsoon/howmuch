import { useState } from "react";
import { api, useApi, type RewardsAccountConfig, type RewardsTrackerImportResult } from "../api/client";
import { SettingsCrumb } from "../components/SettingsCrumb";
import { portableRewardsExport } from "../lib/rewards-export";
import { usePlan } from "../state/plan";

export function RewardsImportPage() {
  const { planId, reload } = usePlan();
  const [generation, setGeneration] = useState(0);
  const [fileName, setFileName] = useState<string | null>(null);
  const [payload, setPayload] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<RewardsTrackerImportResult | null>(null);
  const snapshot = useApi(`rewards-tracker:${planId}:${generation}`, () => api.rewardsTrackerSnapshot(planId));

  const chooseFile = async (file: File | undefined) => {
    setError(null);
    setResult(null);
    setPayload(null);
    setFileName(null);
    if (!file) return;
    try {
      const parsed = JSON.parse(await file.text()) as unknown;
      setPayload(parsed);
      setFileName(file.name);
    } catch {
      setError("That file is not valid JSON. Export settings from Rewards Tracker, then choose the .json file.");
    }
  };

  const importFile = async () => {
    if (payload == null || busy) return;
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      const imported = await api.importRewardsTracker(planId, payload);
      setResult(imported);
      setGeneration((value) => value + 1);
      reload();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const cards = snapshot.data?.cards ?? [];
  const exportFile = () => {
    if (!snapshot.data) return;
    const url = URL.createObjectURL(new Blob([JSON.stringify(portableRewardsExport(snapshot.data), null, 2)], { type: "application/json" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "halation-rewards.json";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  return (
    <>
      <header className="report-header">
        <SettingsCrumb current="Rewards import" />
      </header>

      <AccountConfigExchange key={planId} busy={busy} setBusy={setBusy} configuredAccounts={cards.map((card) => card.ynabAccountId)} onImported={() => {
        setGeneration((value) => value + 1);
        reload();
      }} />

      <section className="report-section" aria-label="Export rewards">
        <h2>Whole-app rewards settings</h2>
        <button type="button" className="save-button" disabled={!snapshot.data || snapshot.loading || busy} onClick={exportFile}>Export rewards JSON</button>
        <p className="field-note">Portable current cards, rules, tag mappings, and reward settings. No API credentials, connection settings, or cached transactions. Account IDs are retained for re-import.</p>
      </section>

      <p className="diagnostic-note">
        Import a Rewards Tracker for YNAB settings export. Cards, rules, and tag mappings are stored on this plan.
        Cached YNAB-shaped accounts and transactions in older dumps are upserted by their original IDs, so running the
        import twice updates the same rows instead of duplicating them. This does not connect to live YNAB.
      </p>

      <div className="status-panel">
        <p className="status-title">Import replaces the stored card set.</p>
        <p className="status-detail">
          Cards omitted from the export are soft-deleted. An empty <code>cards</code> array removes every Halation card.
          Miles valuation in the export replaces a native value when the export sets a finite number.
        </p>
      </div>

      {error && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not import Rewards Tracker export.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}

      <section className="report-section" aria-labelledby="rewards-import-heading">
        <div className="section-heading">
          <div>
            <span className="section-title" id="rewards-import-heading">Export file</span>
            <span className="section-meta">Settings → Export in Rewards Tracker. PAT and Cloud Sync secrets are ignored.</span>
          </div>
        </div>
        <form
          className="rewards-import-form"
          onSubmit={(event) => {
            event.preventDefault();
            void importFile();
          }}
        >
          <label className="field">
            <span className="field-label">Rewards Tracker export</span>
            <input
              type="file"
              accept="application/json,.json"
              aria-label="Rewards Tracker export"
              onChange={(event) => void chooseFile(event.target.files?.[0])}
            />
          </label>
          <button type="submit" className="save-button" disabled={busy || payload == null}>
            {busy ? "Importing…" : "Import export"}
          </button>
        </form>
        {fileName && <p className="rewards-import-file" role="status">Selected {fileName}</p>}
      </section>

      {result && (
        <section className="report-section" aria-labelledby="rewards-import-result-heading">
          <div className="section-heading">
            <span className="section-title" id="rewards-import-result-heading">Imported this session</span>
          </div>
          <dl className="rewards-import-counts">
            <Count label="Cards" value={result.cards} />
            <Count label="Rules" value={result.rules} />
            <Count label="Tag mappings" value={result.tag_mappings} />
            <Count label="Accounts upserted" value={result.accounts_upserted} />
            <Count label="Transactions imported" value={result.transactions_imported} />
            <Count label="Transactions updated" value={result.transactions_updated} />
            <Count label="Flag names" value={result.flag_names} />
          </dl>
        </section>
      )}

      <section className="report-section" aria-labelledby="rewards-cards-heading">
        <div className="section-heading">
          <span className="section-title" id="rewards-cards-heading">Stored cards</span>
          <span className="section-meta">{cards.length} stored</span>
        </div>
        {snapshot.loading && !snapshot.data && <div className="status-panel"><p className="status-title">Loading stored cards…</p></div>}
        {snapshot.error && (
          <div className="status-panel status-panel-error" role="alert">
            <p className="status-title">Could not load stored cards.</p>
            <p className="status-detail">{snapshot.error}</p>
          </div>
        )}
        {!snapshot.loading && !snapshot.error && cards.length === 0 && (
          <p className="rewards-import-empty">No Rewards Tracker cards stored yet.</p>
        )}
        {cards.length > 0 && (
          <ul className="rewards-card-list">
            {cards.map((card) => (
              <li key={card.id}>
                <strong>{card.name}</strong>
                <span>{[card.issuer, card.type].filter(Boolean).join(" · ") || "Card"}</span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}

function AccountConfigExchange({ busy, setBusy, configuredAccounts, onImported }: {
  busy: boolean;
  setBusy: (busy: boolean) => void;
  configuredAccounts: string[];
  onImported: () => void;
}) {
  const { planId, accounts } = usePlan();
  const [accountId, setAccountId] = useState("");
  const [file, setFile] = useState<RewardsAccountConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const account = accounts.find((entry) => entry.id === accountId);

  const chooseFile = async (selected: File | undefined) => {
    setFile(null);
    setError(null);
    setMessage(null);
    if (!selected) return;
    setBusy(true);
    try {
      const parsed = JSON.parse(await selected.text());
      if (parsed?.format !== "rewards-account-config" || parsed?.version !== 1 || !parsed.card || typeof parsed.card.name !== "string") {
        throw new Error("Choose a per-account rewards config version 1 file, not a whole-app settings export.");
      }
      setFile(parsed);
    } catch (cause) {
      setError(cause instanceof SyntaxError ? "That file is not valid JSON." : cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const exchange = async (action: "export" | "import") => {
    if (!account || busy || (action === "import" && !file)) return;
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      if (action === "import") {
        await api.importRewardsAccountConfig(planId, account.id, file);
        setMessage(`Rewards configuration imported to ${account.name}. Transactions and other accounts are unchanged.`);
        onImported();
      } else {
        const exported = await api.exportRewardsAccountConfig(planId, account.id);
        const url = URL.createObjectURL(new Blob([JSON.stringify(exported, null, 2)], { type: "application/json" }));
        const link = document.createElement("a");
        link.href = url;
        link.download = `${account.name.replace(/[^a-z0-9_-]+/gi, "-")}-rewards-config.json`;
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        setMessage(`Exported rewards configuration for ${account.name}.`);
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="report-section" aria-labelledby="account-config-heading">
      <h2 id="account-config-heading">One account’s rewards configuration</h2>
      <p className="field-note">Exchange rates, tiers, caps, periods and flag categories with Rewards Tracker. No transactions, account IDs, global settings or credentials.</p>
      <div className="rewards-import-form">
        <label className="field">
          <span className="field-label">Account for export or import</span>
          <select value={accountId} disabled={busy} onChange={(event) => { setAccountId(event.target.value); setMessage(null); setError(null); }}>
            <option value="">Choose an account…</option>
            {accounts.filter((entry) => !entry.closed || configuredAccounts.includes(entry.id)).map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
          </select>
        </label>
        <button type="button" className="save-button" disabled={busy || !account || !configuredAccounts.includes(accountId)} onClick={() => void exchange("export")}>Export account config</button>
      </div>
      <div className="rewards-import-form">
        <label className="field">
          <span className="field-label">Per-account rewards JSON</span>
          <input type="file" accept="application/json,.json" disabled={busy} onChange={(event) => void chooseFile(event.target.files?.[0])} />
        </label>
        <button type="button" className="save-button" disabled={busy || !account || !file} onClick={() => void exchange("import")}>Import account config</button>
      </div>
      {file && <p className="field-note">Selected configuration: <strong>{file.card.name}</strong>. {account ? <>Import replaces only the rewards configuration for <strong>{account.name}</strong>, including clearing old settings absent from the file.</> : "Choose the destination account above."}</p>}
      <p className="field-note">The destination account’s name stays. Other accounts and all ledger transactions stay unchanged.</p>
      {error && <p className="status-panel status-panel-error" role="alert">{error}</p>}
      {message && <p className="status-panel" role="status">{message}</p>}
    </section>
  );
}

function Count({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}
