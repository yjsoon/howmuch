import { NavLink } from "react-router-dom";

export function SettingsCrumb({ current }: { current: string }) {
  return (
    <nav className="settings-crumb" aria-label="Breadcrumb">
      <ol>
        <li>
          <NavLink to="/settings">Settings</NavLink>
        </li>
        <li aria-current="page">
          <h1>{current}</h1>
        </li>
      </ol>
    </nav>
  );
}
