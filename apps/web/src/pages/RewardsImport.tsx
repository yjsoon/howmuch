import { useState } from "react";
import { api, useApi, type RewardsTrackerImportResult } from "../api/client";
import { usePlan } from "../state/plan";

export function RewardsImportPage() {
  const { planId } = usePlan();
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
    try {
      const imported = await api.importRewardsTracker(planId, payload);
      setResult(imported);
      setGeneration((value) => value + 1);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const cards = snapshot.data?.cards ?? [];

  return (
    <>
      <header className="report-header">
        <div>
          <span className="page-eyebrow">Cutover</span>
          <h1>Rewards import</h1>
        </div>
      </header>

      <p className="diagnostic-note">
        Import a Rewards Tracker for YNAB settings export. Cards, rules, and tag mappings are stored on this plan.
        Cached YNAB-shaped accounts and transactions in older dumps are upserted by their original IDs, so running the
        import twice updates the same rows instead of duplicating them. This does not connect to live YNAB.
      </p>

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

function Count({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}
