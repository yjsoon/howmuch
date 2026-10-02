import { useState } from "react";
import { api, useApi, type CreatedPersonalApiToken } from "../api/client";
import { SettingsCrumb } from "../components/SettingsCrumb";

export function ApiTokensPage() {
  const [generation, setGeneration] = useState(0);
  const [name, setName] = useState("");
  const [created, setCreated] = useState<CreatedPersonalApiToken | null>(null);
  const [copyStatus, setCopyStatus] = useState<string | null>(null);
  const [pendingRevoke, setPendingRevoke] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const tokens = useApi(`personal-api-tokens:${generation}`, api.personalApiTokens);
  const active = (tokens.data ?? []).filter((token) => token.revoked_at === null);
  const revoked = (tokens.data ?? []).filter((token) => token.revoked_at !== null);

  const createToken = async () => {
    setBusy("create");
    setError(null);
    setCopyStatus(null);
    try {
      const result = await api.createPersonalApiToken(name);
      setCreated(result);
      setName("");
      setGeneration((value) => value + 1);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  const copyToken = async () => {
    if (!created) return;
    try {
      await navigator.clipboard.writeText(created.value);
      setCopyStatus("Copied to clipboard.");
    } catch {
      setCopyStatus("Select the token and copy it manually.");
    }
  };

  const revokeToken = async (id: string) => {
    if (busy !== null) return;
    setBusy(id);
    setError(null);
    try {
      await api.revokePersonalApiToken(id);
      setPendingRevoke(null);
      setCreated((current) => current?.token.id === id ? null : current);
      setGeneration((value) => value + 1);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  return (
    <>
      <header className="report-header api-token-header">
        <SettingsCrumb current="API tokens" />
        <p className="api-token-endpoint">
          <span>Base URL</span>
          <code>{window.location.origin}/v1</code>
          <a href="/docs">API documentation →</a>
        </p>
      </header>

      <p className="diagnostic-note">Personal tokens use your current plan permissions. They remain valid until you revoke them.</p>

      {error && <div className="status-panel status-panel-error" role="alert"><p className="status-title">Could not update API tokens.</p><p className="status-detail">{error}</p></div>}

      {created && (
        <section className="api-token-reveal" aria-labelledby="new-token-heading">
          <div className="api-token-reveal-copy">
            <span className="page-eyebrow">Shown once</span>
            <h2 id="new-token-heading">Save this token now</h2>
            <p>Halation stores only its fingerprint. You cannot reveal it again after dismissing this panel.</p>
          </div>
          <div className="api-token-secret-row">
            <input
              aria-label="New personal API token"
              className="api-token-secret"
              value={created.value}
              readOnly
              spellCheck={false}
              onFocus={(event) => event.currentTarget.select()}
            />
            <button type="button" className="api-token-copy" onClick={() => void copyToken()}>Copy token</button>
          </div>
          <div className="api-token-reveal-footer">
            <span role="status">{copyStatus}</span>
            <button type="button" className="text-button" onClick={() => { setCreated(null); setCopyStatus(null); }}>I’ve saved it</button>
          </div>
        </section>
      )}

      {!created && (
        <section className="report-section api-token-create" aria-labelledby="create-token-heading">
          <div className="section-heading">
            <div>
              <span className="section-title" id="create-token-heading">Create a token</span>
              <span className="section-meta">Give it the name of the app or device that will use it.</span>
            </div>
          </div>
          <form
            className="api-token-form"
            onSubmit={(event) => { event.preventDefault(); void createToken(); }}
          >
            <label className="field">
              <span className="field-label">Token name</span>
              <input
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="OpenClaw on home server"
                maxLength={64}
                autoComplete="off"
                required
              />
            </label>
            <button type="submit" className="save-button api-token-create-button" disabled={busy !== null || !name.trim()}>
              {busy === "create" ? "Creating…" : "Create token"}
            </button>
          </form>
        </section>
      )}

      <section className="report-section" aria-labelledby="active-token-heading">
        <div className="section-heading">
          <span className="section-title" id="active-token-heading">Active tokens</span>
          <span className="section-meta">{active.length} active</span>
        </div>
        {tokens.loading && !tokens.data && <div className="status-panel"><p className="status-title">Loading API tokens…</p></div>}
        {tokens.error && <div className="status-panel status-panel-error" role="alert"><p className="status-title">Could not load API tokens.</p><p className="status-detail">{tokens.error}</p></div>}
        {!tokens.loading && !tokens.error && active.length === 0 && <p className="api-token-empty">No active tokens. Create one when an app needs direct access to Halation.</p>}
        {active.length > 0 && (
          <ul className="api-token-list">
            {active.map((token) => (
              <li key={token.id}>
                <div>
                  <strong>{token.name}</strong>
                  <span>Created {formatTimestamp(token.created_at)}</span>
                </div>
                {pendingRevoke === token.id ? (
                  <div className="api-token-confirm">
                    <span>Stop this token immediately?</span>
                    <button type="button" className="text-button" onClick={() => setPendingRevoke(null)} disabled={busy !== null}>Cancel</button>
                    <button type="button" className="api-token-revoke" onClick={() => void revokeToken(token.id)} disabled={busy !== null}>{busy === token.id ? "Revoking…" : "Revoke"}</button>
                  </div>
                ) : (
                  <button type="button" className="api-token-revoke" onClick={() => setPendingRevoke(token.id)} disabled={busy !== null}>Revoke</button>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      {revoked.length > 0 && (
        <details className="api-token-history">
          <summary>Revoked tokens ({revoked.length})</summary>
          <ul>
            {revoked.map((token) => <li key={token.id}><span>{token.name}</span><span>Revoked {formatTimestamp(token.revoked_at!)}</span></li>)}
          </ul>
        </details>
      )}
    </>
  );
}

function formatTimestamp(timestamp: number): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(timestamp * 1_000));
}
