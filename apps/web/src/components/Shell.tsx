import { Suspense, useEffect, useMemo, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { api, type TransactionPage } from "../api/client";
import type { AccountPreferences } from "../api/types";
import { formatMoney } from "../lib/money";
import { accountGroups as buildAccountGroups, type AccountGroup } from "../lib/account-groups";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";
import { AccountOrganizationDialog, type AccountUsageState } from "./AccountOrganizationDialog";

const REPORTS = [
  { to: "/spending", label: "Spending breakdown" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
];

export function Shell() {
  const location = useLocation();
  const { planId, accounts, accountPreferences, updateAccountPreferences, logout } = usePlan();
  const { filters } = useFilters();
  const [logoutError, setLogoutError] = useState<string | null>(null);
  const [organizerOpen, setOrganizerOpen] = useState(false);
  const [usageGeneration, setUsageGeneration] = useState(0);
  const [accountUsage, setAccountUsage] = useState<{
    counts?: Record<string, number>;
    state: AccountUsageState;
  }>({ state: { phase: "idle", message: null } });
  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const accountGroups = useMemo(
    () => buildAccountGroups(accounts, accountPreferences, accountUsage.counts),
    [accounts, accountPreferences, accountUsage.counts],
  );
  const usesMostUsedSort = accountPreferences
    ? Object.values(accountPreferences.account_group_sorts).includes("mostUsedLast30Days")
    : false;
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

  useEffect(() => {
    if (!usesMostUsedSort) {
      setAccountUsage({ state: { phase: "idle", message: null } });
      return;
    }
    let cancelled = false;
    setAccountUsage((current) => ({ ...current, state: { phase: "loading", message: null } }));
    loadAccountUsageLast30Days(planId)
      .then((counts) => {
        if (cancelled) return;
        setAccountUsage({ counts, state: { phase: "loaded", message: null } });
      })
      .catch((cause) => {
        if (!cancelled) {
          setAccountUsage({
            state: { phase: "error", message: cause instanceof Error ? cause.message : String(cause) },
          });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [planId, usesMostUsedSort, usageGeneration]);

  useEffect(() => {
    if (!accountPreferences || !accountUsage.counts) return;
    updateAccountPreferences((current) => snapshotMostUsedOrders(
      current,
      buildAccountGroups(accounts, current, accountUsage.counts),
    ));
  }, [accounts, accountPreferences, accountUsage.counts]);

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
          <button type="button" className="sidebar-primary-link account-organizer-entry" onClick={() => setOrganizerOpen(true)}>
            <span aria-hidden="true">☷</span> Organise accounts
          </button>
        </nav>

        <div className="account-list">
          {accountGroups.map((group) => (
            <section key={group.id} className="account-group">
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
            <button type="button" className="mobile-organizer-entry" onClick={() => setOrganizerOpen(true)}>Organise</button>
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
      {organizerOpen && (
        <AccountOrganizationDialog
          accountGroups={accountGroups}
          usage={accountUsage.state}
          onRetryUsage={() => setUsageGeneration((generation) => generation + 1)}
          onClose={() => setOrganizerOpen(false)}
        />
      )}
    </div>
  );
}

function snapshotMostUsedOrders(preferences: AccountPreferences, groups: AccountGroup[]): AccountPreferences {
  let changed = false;
  const accountOrderByGroup = { ...preferences.account_order_by_group };
  for (const group of groups) {
    if (preferences.account_group_sorts[group.id] !== "mostUsedLast30Days") continue;
    const order = group.accounts.map((account) => account.id);
    if (JSON.stringify(accountOrderByGroup[group.id] ?? []) !== JSON.stringify(order)) {
      accountOrderByGroup[group.id] = order;
      changed = true;
    }
  }
  return changed ? { ...preferences, account_order_by_group: accountOrderByGroup } : preferences;
}

async function loadAccountUsageLast30Days(planId: string): Promise<Record<string, number>> {
  const today = new Date();
  const start = new Date(today);
  start.setDate(start.getDate() - 29);
  const sinceDate = localIsoDate(start);
  const untilDate = localIsoDate(today);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const counts: Record<string, number> = {};
    const transactionIds = new Set<string>();
    const requestedOffsets = new Set<number>();
    let offset = 0;
    let expectedKnowledge: number | undefined;
    let ledgerChanged = false;
    while (requestedOffsets.size < 250) {
      if (requestedOffsets.has(offset)) throw new Error("The transaction usage cursor repeated.");
      requestedOffsets.add(offset);
      const page: TransactionPage = await api.transactions(planId, {
        since_date: sinceDate,
        until_date: untilDate,
        limit: 250,
        offset,
      });
      if (expectedKnowledge !== undefined && page.server_knowledge !== expectedKnowledge) {
        ledgerChanged = true;
        break;
      }
      expectedKnowledge = page.server_knowledge;
      for (const transaction of page.transactions) {
        if (transaction.date >= sinceDate && transaction.date <= untilDate && !transactionIds.has(transaction.id)) {
          transactionIds.add(transaction.id);
          counts[transaction.account_id] = (counts[transaction.account_id] ?? 0) + 1;
        }
      }
      if (!page.has_more) return counts;
      if (page.transactions.length === 0) throw new Error("The transaction usage page was empty before the final page.");
      if (page.next_offset === null || page.next_offset <= offset) {
        throw new Error("The transaction usage cursor did not advance.");
      }
      offset = page.next_offset;
    }
    if (!ledgerChanged && requestedOffsets.size >= 250) {
      throw new Error("The transaction usage scan exceeded its safe page limit.");
    }
  }
  throw new Error("Transactions changed while usage was loading. Try again.");
}

function localIsoDate(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}
