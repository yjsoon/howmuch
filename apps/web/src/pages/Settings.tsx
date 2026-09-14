import { NavLink } from "react-router-dom";

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
