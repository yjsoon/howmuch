import { useState, type FormEvent } from "react";
import { NavLink } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { PlanSettings } from "../api/types";
import {
  buildPlanSeed,
  CURRENCY_CHOICES,
  DATE_FORMAT_CHOICES,
  type DateFormatChoice,
} from "../lib/locale-plan-seed";
import { usePlan } from "../state/plan";

const MIN_PASSWORD_LENGTH = 15;

const TOOLS = [
  {
    to: "/tools/reward-terms",
    name: "Reward terms",
    detail: "Use your own AI provider key to draft and review card reward rules.",
  },
  {
    to: "/tools/statement-formatter",
    name: "Statement formatter",
    detail: "Extract statement images into editable CSV rows with your own provider key.",
  },
  {
    to: "/api-tokens",
    name: "API tokens",
    detail: "Mint and revoke personal tokens for the /v1 API.",
  },
  {
    to: "/import/rewards",
    name: "Rewards import",
    detail: "One-off import of a Rewards Tracker for YNAB settings export.",
  },
];

export function SettingsPage() {
  const { planId } = usePlan();
  // Formats as last saved here; they win over the first read so the form
  // reflects a save without a refetch (a refetch would unmount the section and
  // lose its confirmation message).
  const [saved, setSaved] = useState<PlanSettings | null>(null);
  // The role comes from the session check and the formats from the plan, so
  // the owner-only section reflects what the server will actually accept.
  const account = useApi(`settings-account:${planId}`, async () => {
    const [status, settings] = await Promise.all([api.authStatus(), api.settings(planId)]);
    return { isOwner: status.roles?.[planId] === "owner", settings };
  });

  return (
    <>
      <header className="report-header">
        <div>
          <h1>Settings</h1>
        </div>
      </header>

      <p className="diagnostic-note">
        Your password, plan formats, tokens and imports live here so the daily ledger stays uncluttered.
      </p>

      <ChangePasswordSection />

      {account.data?.isOwner && (
        <PlanFormatsSection settings={saved ?? account.data.settings} onSaved={setSaved} />
      )}

      <section className="report-section" aria-labelledby="settings-tools-heading">
        <div className="section-heading">
          <span className="section-title" id="settings-tools-heading">Tools</span>
        </div>
        <ul className="settings-tool-list">
          {TOOLS.map((tool) => (
            <li key={tool.to}>
              <NavLink to={tool.to} className="settings-tool-link">
                <strong>{tool.name}</strong>
                <span>{tool.detail}</span>
              </NavLink>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

function ChangePasswordSection() {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setDone(false);
    if (Array.from(next).length < MIN_PASSWORD_LENGTH) {
      setError(`The new password needs at least ${MIN_PASSWORD_LENGTH} characters.`);
      return;
    }
    if (next !== confirm) {
      setError("The new password and its confirmation do not match.");
      return;
    }
    if (next === current) {
      setError("The new password must differ from the current one.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.changePassword(current, next);
      setCurrent("");
      setNext("");
      setConfirm("");
      setDone(true);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="report-section" aria-labelledby="settings-password-heading">
      <div className="section-heading settings-heading">
        <div>
          <span className="section-title" id="settings-password-heading">Change password</span>
          <span className="section-meta">
            Use at least {MIN_PASSWORD_LENGTH} characters. Every other browser and device signed in as you is signed out. Personal API tokens keep working;
            revoke them on the <NavLink to="/api-tokens">API tokens</NavLink> page if you need to.
          </span>
        </div>
      </div>
      <form className="settings-form" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span className="field-label">Current password</span>
          <input type="password" value={current} onChange={(event) => setCurrent(event.target.value)} autoComplete="current-password" required />
        </label>
        <label className="field">
          <span className="field-label">New password</span>
          <input type="password" value={next} onChange={(event) => setNext(event.target.value)} autoComplete="new-password" minLength={MIN_PASSWORD_LENGTH} required />
        </label>
        <label className="field">
          <span className="field-label">Confirm new password</span>
          <input type="password" value={confirm} onChange={(event) => setConfirm(event.target.value)} autoComplete="new-password" minLength={MIN_PASSWORD_LENGTH} required />
        </label>
        <button type="submit" className="save-button settings-form-button" disabled={busy || !current || !next || !confirm}>
          {busy ? "Changing…" : "Change password"}
        </button>
      </form>
      {error && <div className="status-panel status-panel-error" role="alert"><p className="status-detail">{error}</p></div>}
      {done && <div className="status-panel status-panel-success" role="status"><p className="status-detail">Password changed. Other sessions have been signed out.</p></div>}
    </section>
  );
}

function PlanFormatsSection({ settings, onSaved }: { settings: PlanSettings; onSaved: (settings: PlanSettings) => void }) {
  const { planId, reload } = usePlan();
  const savedCurrency = settings.currency_format?.iso_code ?? "";
  const savedDate = settings.date_format?.format ?? "";
  const [currency, setCurrency] = useState(savedCurrency);
  const [dateFormat, setDateFormat] = useState(savedDate);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  // A plan imported from elsewhere may use a value the form does not offer;
  // keep it selectable so the select shows the truth.
  const currencies = CURRENCY_CHOICES.includes(savedCurrency) || !savedCurrency ? CURRENCY_CHOICES : [savedCurrency, ...CURRENCY_CHOICES];
  const dateFormats: readonly string[] = DATE_FORMAT_CHOICES.includes(savedDate as DateFormatChoice) || !savedDate
    ? DATE_FORMAT_CHOICES
    : [savedDate, ...DATE_FORMAT_CHOICES];
  const changed = currency !== savedCurrency || dateFormat !== savedDate;

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setDone(false);
    try {
      // Only what changed is sent, so an untouched custom format stays as it is.
      const seed = buildPlanSeed(currency, dateFormat as DateFormatChoice);
      const updated = await api.updatePlanFormats(planId, {
        ...(currency !== savedCurrency ? { currency_format: seed.currency_format } : {}),
        ...(dateFormat !== savedDate ? { date_format: seed.date_format } : {}),
      } as Parameters<typeof api.updatePlanFormats>[1]);
      setDone(true);
      onSaved(updated);
      // Re-reads the plan settings so amounts and dates repaint without a manual reload.
      reload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="report-section" aria-labelledby="settings-formats-heading">
      <div className="section-heading settings-heading">
        <div>
          <span className="section-title" id="settings-formats-heading">Currency and date format</span>
          <span className="section-meta">
            Amounts are stored as exact milliunits with no currency attached, so changing the currency changes how
            amounts are shown and does not convert them. A balance of 100.00 in one currency shows as 100.00 in the next.
          </span>
        </div>
      </div>
      <form className="settings-form" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span className="field-label">Currency</span>
          <select value={currency} onChange={(event) => { setCurrency(event.target.value); setDone(false); }}>
            {currencies.map((code) => <option key={code} value={code}>{code}</option>)}
          </select>
        </label>
        <label className="field">
          <span className="field-label">Date format</span>
          <select value={dateFormat} onChange={(event) => { setDateFormat(event.target.value); setDone(false); }}>
            {dateFormats.map((format) => <option key={format} value={format}>{format}</option>)}
          </select>
        </label>
        <button type="submit" className="save-button settings-form-button" disabled={busy || !changed}>
          {busy ? "Saving…" : "Save formats"}
        </button>
      </form>
      {error && <div className="status-panel status-panel-error" role="alert"><p className="status-detail">{error}</p></div>}
      {done && <div className="status-panel status-panel-success" role="status"><p className="status-detail">Formats saved. Amounts and dates now use the new settings.</p></div>}
    </section>
  );
}
