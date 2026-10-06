import { NavLink } from "react-router-dom";
import { LOOKS, setTheme, useTheme, type Mode } from "../lib/theme";

const MODES: ReadonlyArray<{ id: Mode; label: string }> = [
  { id: "system", label: "Match system" },
  { id: "light", label: "Light" },
  { id: "dark", label: "Dark" },
];

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
  const theme = useTheme();
  return (
    <>
      <header className="report-header">
        <div>
          <h1>Settings</h1>
        </div>
      </header>

      <p className="diagnostic-note">
        Tokens and imports live here so the daily ledger stays uncluttered.
      </p>

      <section className="report-section" aria-labelledby="settings-appearance-heading">
        <div className="section-heading">
          <span className="section-title" id="settings-appearance-heading">Appearance</span>
          <span className="section-meta">Saved on this device</span>
        </div>
        <div className="theme-picker" role="radiogroup" aria-labelledby="settings-appearance-heading">
          {LOOKS.map((look) => (
            <label key={look.id} className="theme-option" data-look={look.id}>
              <input
                type="radio"
                name="halation-look"
                value={look.id}
                checked={theme.look === look.id}
                onChange={() => setTheme({ look: look.id })}
              />
              <span className="theme-swatch" aria-hidden="true">
                <span className="theme-swatch-chrome" />
                <span className="theme-swatch-paper" />
              </span>
              <span className="theme-option-name">
                {look.name}
                {look.id === "dusk-ridge" && <small> · default</small>}
              </span>
              <span className="theme-option-note">{look.note}</span>
            </label>
          ))}
        </div>
        <div className="segmented" role="group" aria-label="Colour mode">
          {MODES.map((mode) => (
            <button
              key={mode.id}
              type="button"
              aria-pressed={theme.mode === mode.id}
              className={theme.mode === mode.id ? "segment segment-active" : "segment"}
              onClick={() => setTheme({ mode: mode.id })}
            >
              {mode.label}
            </button>
          ))}
        </div>
      </section>

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
