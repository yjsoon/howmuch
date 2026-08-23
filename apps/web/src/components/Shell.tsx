import { Suspense, useEffect, useMemo, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

const REPORTS = [
  { to: "/spending", label: "Spending breakdown" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
];

export function Shell() {
  const location = useLocation();
  const { accounts, logout } = usePlan();
  const { filters } = useFilters();
  const [logoutError, setLogoutError] = useState<string | null>(null);
  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const accountGroups = useMemo(
    () => [
      { label: "Budget", accounts: openAccounts.filter((account) => account.on_budget) },
      { label: "Tracking", accounts: openAccounts.filter((account) => !account.on_budget) },
    ].filter((group) => group.accounts.length > 0),
    [openAccounts],
  );
  const selectedAccount = location.pathname === "/transactions" && filters.accountIds.length === 1
    ? accounts.find((account) => account.id === filters.accountIds[0])
    : undefined;
  const registerLabel = filters.accountIds.length === 0
    ? "All Accounts"
    : selectedAccount?.name ?? (filters.accountIds.length === 1 ? "Account unavailable" : "Selected Accounts");
  const handleLogout = async () => {
    setLogoutError(null);
    try {
      await logout();
    } catch (cause) {
      setLogoutError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  useEffect(() => {
    const report = REPORTS.find((entry) => entry.to === location.pathname);
    const label = (location.pathname === "/transactions" ? registerLabel : null)
      ?? (location.pathname === "/plan" ? "Plan" : null)
      ?? (location.pathname === "/scheduled" ? "Scheduled transactions" : null)
      ?? (location.pathname === "/api-tokens" ? "API tokens" : null)
      ?? report?.label;
    document.title = label ? `${label} · HowMuch` : "HowMuch";
  }, [location.pathname, registerLabel]);

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <span className="brand-mark" aria-hidden="true">H</span>
          <span>
            <strong>HowMuch</strong>
            <small>Your money, clearly</small>
          </span>
        </div>

        <nav className="sidebar-nav" aria-label="Primary navigation">
          <NavLink
            to={{ pathname: "/plan", search: location.search }}
            className={({ isActive }) => isActive ? "sidebar-primary-link sidebar-link-active" : "sidebar-primary-link"}
          >
            <span aria-hidden="true">▦</span> Plan
          </NavLink>
          <NavLink
            to={{ pathname: "/scheduled", search: location.search }}
            className={({ isActive }) => isActive ? "sidebar-primary-link sidebar-link-active" : "sidebar-primary-link"}
          >
            <span aria-hidden="true">◷</span> Scheduled
          </NavLink>
          <NavLink
            to="/api-tokens"
            className={({ isActive }) => isActive ? "sidebar-primary-link sidebar-link-active" : "sidebar-primary-link"}
          >
            <span aria-hidden="true">⌁</span> API tokens
          </NavLink>
          <div className="sidebar-section-label">Reflect</div>
          {REPORTS.map((report) => (
            <NavLink
              key={report.to}
              to={{ pathname: report.to, search: location.search }}
              className={({ isActive }) => (isActive ? "sidebar-report-link sidebar-link-active" : "sidebar-report-link")}
            >
              {report.label}
            </NavLink>
          ))}
          <NavLink
            to="/transactions?range=all&accounts=all"
            className={({ isActive }) =>
              isActive && filters.accountIds.length === 0
                ? "sidebar-primary-link sidebar-link-active"
                : "sidebar-primary-link"
            }
          >
            <span aria-hidden="true">▤</span> All Accounts
            <span className="sidebar-balance" title="Open-account working balance">{formatMoney(openAccounts.reduce((sum, account) => sum + account.balance, 0))}</span>
          </NavLink>
        </nav>

        <div className="account-list">
          {accountGroups.map((group) => (
            <section key={group.label} className="account-group">
              <div className="account-group-heading">
                <span>{group.label}</span>
                <span>{formatMoney(group.accounts.reduce((sum, account) => sum + account.balance, 0))}</span>
              </div>
              {group.accounts.map((account) => (
                <NavLink
                  key={account.id}
                  to={`/transactions?range=all&accounts=${encodeURIComponent(account.id)}`}
                  className={selectedAccount?.id === account.id ? "account-link sidebar-link-active" : "account-link"}
                >
                  <span className="account-name" title={account.name}>{account.name}</span>
                  <span className={account.balance < 0 ? "sidebar-balance sidebar-balance-negative" : "sidebar-balance"}>
                    {formatMoney(account.balance)}
                  </span>
                </NavLink>
              ))}
            </section>
          ))}
        </div>

        <div className="sidebar-footer">
          <NavLink to="/add" className="add-button">+ Add transaction</NavLink>
          <button
            type="button"
            className="sign-out-button"
            onClick={handleLogout}
          >
            Sign out
          </button>
          {logoutError && <span className="masthead-error" role="alert">{logoutError}</span>}
        </div>
      </aside>
      <div className="workspace">
        <header className="mobile-masthead">
          <span className="masthead-title">HowMuch</span>
          <div className="mobile-actions">
            <NavLink to="/add" className="add-button">+ Add</NavLink>
            <button type="button" className="sign-out-button" onClick={handleLogout}>Sign out</button>
          </div>
          {logoutError && <span className="mobile-masthead-error" role="alert">{logoutError}</span>}
        </header>
        <main className="report-body">
          <Suspense fallback={<div className="boot-message">Loading…</div>}>
            <Outlet />
          </Suspense>
        </main>
      </div>
    </div>
  );
}
