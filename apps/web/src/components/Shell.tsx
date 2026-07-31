import { useEffect, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { usePlan } from "../state/plan";

const TABS = [
  { to: "/spending", label: "Spending" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
  { to: "/transactions", label: "Transactions" },
];

export function Shell() {
  const location = useLocation();
  const { logout } = usePlan();
  const [logoutError, setLogoutError] = useState<string | null>(null);
  useEffect(() => {
    const tab = TABS.find((entry) => entry.to === location.pathname);
    document.title = tab ? `${tab.label} · HowMuch` : "HowMuch";
  }, [location.pathname]);
  return (
    <div className="shell">
      <header className="masthead">
        <span className="masthead-title">HowMuch</span>
        <nav className="masthead-nav">
          {TABS.map((tab) => (
            <NavLink
              key={tab.to}
              to={{ pathname: tab.to, search: location.search }}
              className={({ isActive }) => (isActive ? "tab tab-active" : "tab")}
            >
              {tab.label}
            </NavLink>
          ))}
        </nav>
        <NavLink to="/add" className="add-button">
          + Add
        </NavLink>
        <button
          type="button"
          className="sign-out-button"
          onClick={async () => {
            setLogoutError(null);
            try {
              await logout();
            } catch (cause) {
              setLogoutError(cause instanceof Error ? cause.message : String(cause));
            }
          }}
        >
          Sign out
        </button>
        {logoutError && <span className="masthead-error" role="alert">{logoutError}</span>}
      </header>
      <main className="report-body">
        <Outlet />
      </main>
    </div>
  );
}
