import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { api } from "../api/client";
import type { AccountPreferences } from "../api/types";
import { formatMoney } from "../lib/money";
import { addEntryHref } from "../lib/register-compose";
import { ACCOUNT_USAGE_DAYS, accountUsageCounts, localIsoDate } from "../lib/account-usage";
import {
  accountGroups as buildAccountGroups,
  partitionAccountGroups,
  type AccountGroup,
} from "../lib/account-groups";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";
import { AccountOrganizationDialog, type AccountUsageState } from "./AccountOrganizationDialog";
import { AccountIconButton } from "./AccountIconPicker";
import { BrandLockup } from "./Brand";

const REPORTS = [
  { to: "/spending", label: "Spending breakdown" },
  { to: "/income", label: "Income v Spending" },
  { to: "/net-worth", label: "Net Worth" },
  { to: "/age-of-money", label: "Age of Money" },
  { to: "/rewards", label: "Rewards" },
];

export function Shell() {
  const location = useLocation();
  const {
    planId,
    accounts,
    ledgerKnowledge,
    accountPreferences,
    accountPreferencesSync,
    updateAccountPreferences,
    updateAccountIcon,
    retryAccountPreferences,
    logout,
  } = usePlan();
  const { filters } = useFilters();
  const [logoutError, setLogoutError] = useState<string | null>(null);
  const [mobileNav, setMobileNav] = useState<"closed" | "open">("closed");
  const [organizerOpen, setOrganizerOpen] = useState(false);
  const organizerOpener = useRef<HTMLButtonElement | null>(null);
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
  const { collections, index: typeIndex } = useMemo(
    () => partitionAccountGroups(accountGroups),
    [accountGroups],
  );
  const usesMostUsedSort = accountPreferences
    ? Object.values(accountPreferences.account_group_sorts).includes("mostUsedLast30Days")
    : false;
  const usageDate = localIsoDate(new Date());
  const openOrganizer = (opener: HTMLButtonElement) => {
    organizerOpener.current = opener;
    setOrganizerOpen(true);
  };
  const closeOrganizer = () => {
    setOrganizerOpen(false);
    requestAnimationFrame(() => organizerOpener.current?.focus());
  };
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
    setMobileNav("closed");
  }, [location.pathname, location.search]);

  useEffect(() => {
    if (mobileNav === "closed") return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setMobileNav("closed");
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [mobileNav]);

  useEffect(() => {
    const report = REPORTS.find((entry) => entry.to === location.pathname);
    const label = (location.pathname === "/transactions" ? registerLabel : null)
      ?? (location.pathname === "/scheduled" ? "Scheduled transactions" : null)
      ?? (location.pathname === "/settings" ? "Settings" : null)
      ?? (location.pathname === "/api-tokens" ? "API tokens" : null)
      ?? (location.pathname === "/import/rewards" ? "Rewards import" : null)
      ?? (location.pathname === "/tools/reward-terms" ? "Reward terms" : null)
      ?? (location.pathname === "/tools/statement-formatter" ? "Statement formatter" : null)
      ?? (location.pathname === "/rewards/new" ? "Add card" : null)
      ?? (location.pathname.startsWith("/rewards/") ? "Edit card" : null)
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
    // One grouped query per knowledge change, and only while a group is
    // actually sorted by usage. The window ends on the viewer's local today, so
    // the day boundary stays where the register scan used to put it.
    api.accountUsage(planId, { days: ACCOUNT_USAGE_DAYS, until: usageDate })
      .then((snapshot) => {
        if (cancelled) return;
        setAccountUsage({
          counts: accountUsageCounts(snapshot.usage),
          state: { phase: "loaded", message: null },
        });
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
  }, [planId, ledgerKnowledge, usageDate, usesMostUsedSort, usageGeneration]);

  useEffect(() => {
    if (!accountPreferences || !accountUsage.counts) return;
    updateAccountPreferences((current) => snapshotMostUsedOrders(
      current,
      buildAccountGroups(accounts, current, accountUsage.counts),
    ));
  }, [accounts, accountPreferences, accountUsage.counts]);

  return (
    <div className={mobileNav === "open" ? "shell mobile-nav-open" : "shell"}>
      <header className="mobile-masthead">
        <button
          type="button"
          className="mobile-nav-toggle"
          aria-expanded={mobileNav === "open"}
          aria-controls="primary-navigation"
          onClick={() => setMobileNav((current) => (current === "open" ? "closed" : "open"))}
        >
          <span className="sr-only">{mobileNav === "open" ? "Close menu" : "Open menu"}</span>
          <span className="mobile-nav-toggle-icon" aria-hidden="true">
            <span />
            <span />
            <span />
          </span>
        </button>
        <span className="masthead-title">HowMuch</span>
        <div className="mobile-actions">
          <button
            type="button"
            className="mobile-organizer-entry"
            onClick={(event) => openOrganizer(event.currentTarget)}
          >Organise</button>
          <NavLink to={addEntryHref(selectedAccount && !selectedAccount.closed ? selectedAccount.id : null)} className="add-button">+ Add</NavLink>
          <button type="button" className="sign-out-button" onClick={handleLogout}>Sign out</button>
        </div>
        {logoutError && <span className="mobile-masthead-error" role="alert">{logoutError}</span>}
      </header>
      <aside className="sidebar">
        <div className="sidebar-brand">
          <BrandLockup tagline="Your money, clearly" />
        </div>

        <nav id="primary-navigation" className="sidebar-nav" aria-label="Primary navigation">
          <NavLink
            to={{ pathname: "/scheduled", search: location.search }}
            className={({ isActive }) => isActive ? "sidebar-primary-link sidebar-link-active" : "sidebar-primary-link"}
          >
            <span aria-hidden="true">◷</span> Scheduled
          </NavLink>
          <div className="sidebar-section-label">Reflect</div>
          {REPORTS.map((report) => (
            <NavLink
              key={report.to}
              to={{ pathname: report.to, search: location.search }}
              className={({ isActive }) => {
                const active = report.to === "/rewards"
                  ? location.pathname === "/rewards" || location.pathname.startsWith("/rewards/")
                  : isActive;
                return active ? "sidebar-report-link sidebar-link-active" : "sidebar-report-link";
              }}
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
          <button
            type="button"
            className="sidebar-primary-link account-organizer-entry"
            onClick={(event) => openOrganizer(event.currentTarget)}
          >
            <span aria-hidden="true">☷</span> Organise accounts
          </button>
          <SettingsLink
            className={({ isActive }) =>
              isActive ? "sidebar-primary-link sidebar-settings-nav sidebar-link-active" : "sidebar-primary-link sidebar-settings-nav"
            }
          />
        </nav>

        <div className="account-list">
          {collections.length > 0 && (
            <div className="account-list-band">
              <p className="account-list-band-label">Your groups</p>
              <AccountGroupSections groups={collections} selectedAccountId={selectedAccount?.id} onChangeIcon={updateAccountIcon} />
            </div>
          )}
          {typeIndex.length > 0 && (
            <div className="account-list-band account-list-band-index">
              <p className="account-list-band-label">By type</p>
              <AccountGroupSections groups={typeIndex} selectedAccountId={selectedAccount?.id} tone="index" onChangeIcon={updateAccountIcon} />
            </div>
          )}
        </div>

        <div className="sidebar-footer">
          <NavLink to={addEntryHref(selectedAccount && !selectedAccount.closed ? selectedAccount.id : null)} className="add-button">+ Add transaction</NavLink>
          <div className="sidebar-footer-utilities">
            <SettingsLink
              className={({ isActive }) =>
                isActive ? "sidebar-settings-link sidebar-link-active" : "sidebar-settings-link"
              }
            />
            <button
              type="button"
              className="sign-out-button"
              onClick={handleLogout}
            >
              Sign out
            </button>
          </div>
          {logoutError && <span className="masthead-error" role="alert">{logoutError}</span>}
        </div>
      </aside>
      <div className="workspace">
        <main className="report-body">
          <Suspense fallback={<div className="boot-message">Loading…</div>}>
            <Outlet />
          </Suspense>
        </main>
      </div>
      {!organizerOpen && (
        <AccountOrganizationNotice
          sync={accountPreferencesSync}
          supported={accountPreferences !== null}
          usage={accountUsage.state}
          onRetrySave={retryAccountPreferences}
          onRetryUsage={() => setUsageGeneration((generation) => generation + 1)}
        />
      )}
      {organizerOpen && (
        <AccountOrganizationDialog
          accountGroups={accountGroups}
          usage={accountUsage.state}
          onRetryUsage={() => setUsageGeneration((generation) => generation + 1)}
          onClose={closeOrganizer}
        />
      )}
    </div>
  );
}

function isSettingsPath(pathname: string): boolean {
  return pathname === "/settings" || pathname === "/api-tokens" || pathname === "/import/rewards"
    || pathname === "/tools/reward-terms" || pathname === "/tools/statement-formatter";
}

function SettingsLink({ className }: { className: (state: { isActive: boolean }) => string }) {
  const { pathname } = useLocation();
  return (
    <NavLink to="/settings" className={() => className({ isActive: isSettingsPath(pathname) })}>
      Settings
    </NavLink>
  );
}

function AccountGroupSections({
  groups,
  selectedAccountId,
  tone,
  onChangeIcon,
}: {
  groups: AccountGroup[];
  selectedAccountId: string | undefined;
  tone?: "index";
  onChangeIcon: (accountId: string, icon: string) => Promise<void>;
}) {
  return groups.map((group) => (
    <section key={group.id} className={tone === "index" ? "account-group account-group-index" : "account-group"}>
      <div className="account-group-heading">
        <span>{group.label}</span>
        <span>{formatMoney(group.accounts.reduce((sum, account) => sum + account.balance, 0))}</span>
      </div>
      {group.accounts.map((account) => (
        <div key={account.id} className="account-row">
          <AccountIconButton
            accountName={account.name}
            icon={account.icon}
            onChange={(icon) => onChangeIcon(account.id, icon)}
          />
          <NavLink
            to={`/transactions?range=all&accounts=${encodeURIComponent(account.id)}`}
            className={selectedAccountId === account.id ? "account-link sidebar-link-active" : "account-link"}
          >
            <span className="account-name" title={account.name}>{account.name}</span>
            <span className={account.balance < 0 ? "sidebar-balance sidebar-balance-negative" : "sidebar-balance"}>
              {formatMoney(account.balance)}
            </span>
          </NavLink>
        </div>
      ))}
    </section>
  ));
}

function AccountOrganizationNotice({ sync, supported, usage, onRetrySave, onRetryUsage }: {
  sync: ReturnType<typeof usePlan>["accountPreferencesSync"];
  supported: boolean;
  usage: AccountUsageState;
  onRetrySave: () => void;
  onRetryUsage: () => void;
}) {
  const showSync = sync.phase === "saving" || sync.phase === "error" || (supported && sync.phase === "unsupported");
  const showUsage = usage.phase === "error";
  if (!showSync && !showUsage) return null;
  return (
    <div className="account-organization-global-status" role={sync.phase === "saving" && !showUsage ? "status" : "alert"} aria-live="polite">
      {showSync && (
        <span>
          {sync.message}
          {sync.phase === "error" && <button type="button" onClick={onRetrySave}>Retry save</button>}
        </span>
      )}
      {showUsage && (
        <span>
          30-day account usage is unavailable. <button type="button" onClick={onRetryUsage}>Retry</button>
        </span>
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

