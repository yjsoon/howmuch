import { NavLink, Outlet, useLocation } from "react-router-dom";

const TABS = [
  { to: "/spending", label: "Spending" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
  { to: "/transactions", label: "Transactions" },
];

export function Shell() {
  const location = useLocation();
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
