import { useEffect } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";

const TABS = [
  { to: "/spending", label: "Spending" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
  { to: "/transactions", label: "Transactions" },
  { to: "/accounts", label: "Accounts" },
  { to: "/manage", label: "Manage" },
];

export function Shell() {
  const location = useLocation();
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
      </header>
      <main className="report-body">
        <Outlet />
      </main>
    </div>
  );
}
