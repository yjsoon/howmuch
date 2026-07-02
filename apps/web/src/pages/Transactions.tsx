import { startTransition, useDeferredValue, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { AddTransactionRow, RegisterRow, TransactionEditorRow } from "../components/RegisterRows";
import { ReconcileStrip } from "../components/ReconcileStrip";
import { UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import { formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

export function TransactionsPage() {
  const { filters, setFilters } = useFilters();
  const { planId, accounts, reload } = usePlan();
  const [params] = useSearchParams();
  const [search, setSearch] = useState("");
  const [version, setVersion] = useState(0);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [reconciling, setReconciling] = useState(false);
  const [approving, setApproving] = useState(false);
  const deferredSearch = useDeferredValue(search);
  const flow = params.get("flow");
  const refreshRows = () => setVersion((n) => n + 1);
  const refresh = () => {
    setEditingId(null);
    refreshRows();
  };

  const listKey = JSON.stringify({ planId, from: filters.from, to: filters.to, version });
  const result = useApi(listKey, () =>
    api.transactions(planId, { since_date: filters.from, until_date: filters.to }),
  );
  const payees = useApi(`payees-${planId}-${version}`, () => api.payees(planId));

  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);
  const selectedAccount =
    filters.accountIds.length === 1 ? accounts.find((account) => account.id === filters.accountIds[0]) : undefined;

  const wantsUncategorised = filters.categoryIds.includes(UNCATEGORISED_CATEGORY_ID);
  const accountIds = useMemo(() => new Set(filters.accountIds), [filters.accountIds]);
  const categoryIds = useMemo(
    () => new Set(filters.categoryIds.filter((categoryId) => categoryId !== UNCATEGORISED_CATEGORY_ID)),
    [filters.categoryIds],
  );

  const inScope = useMemo(
    () =>
      (result.data ?? [])
        .filter((txn) => !txn.deleted)
        .filter((txn) => !accountIds.size || accountIds.has(txn.account_id)),
    [accountIds, result.data],
  );

  const uncategorisedCount = useMemo(
    () =>
      inScope.filter(
        (txn) => txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length,
      ).length,
    [inScope],
  );

  const unapproved = useMemo(() => inScope.filter((txn) => !txn.approved), [inScope]);

  const scopedRows = useMemo(() => {
    const outflowOnly = flow === "outflow" || wantsUncategorised;
    return inScope
      .filter((txn) => !outflowOnly || (txn.amount < 0 && !txn.transfer_account_id))
      .filter((txn) => {
        if (!filters.categoryIds.length) {
          return true;
        }

        const matchesCategory =
          (txn.category_id !== null && categoryIds.has(txn.category_id)) ||
          txn.subtransactions?.some((sub) => sub.category_id !== null && categoryIds.has(sub.category_id));
        if (matchesCategory) {
          return true;
        }

        return wantsUncategorised && txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length;
      })
      .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));
  }, [categoryIds, filters.categoryIds.length, flow, inScope, wantsUncategorised]);

  const rows = useMemo(() => {
    const needle = deferredSearch.trim().toLowerCase();
    return scopedRows.filter(
      (txn) =>
        !needle ||
        txn.payee_name?.toLowerCase().includes(needle) ||
        txn.memo?.toLowerCase().includes(needle) ||
        txn.category_name?.toLowerCase().includes(needle) ||
        txn.account_name?.toLowerCase().includes(needle) ||
        txn.subtransactions?.some(
          (sub) =>
            sub.payee_name?.toLowerCase().includes(needle) ||
            sub.memo?.toLowerCase().includes(needle) ||
            sub.category_name?.toLowerCase().includes(needle),
        ),
    );
  }, [deferredSearch, scopedRows]);

  const totals = useMemo(
    () =>
      rows.reduce(
        (summary, txn) => {
          if (txn.amount < 0) {
            summary.outflow += Math.abs(txn.amount);
          } else {
            summary.inflow += txn.amount;
          }
          summary.net += txn.amount;
          return summary;
        },
        { inflow: 0, outflow: 0, net: 0 },
      ),
    [rows],
  );

  const approveAll = async () => {
    setApproving(true);
    try {
      await api.approveTransactions(planId, unapproved.map((txn) => txn.id));
      refreshRows();
    } finally {
      setApproving(false);
    }
  };

  const showAccountColumn = !selectedAccount;
  const rowsChanged = () => {
    reload();
    refreshRows();
  };

  const emptyMessage =
    result.data && result.data.length === 0
      ? "No transactions have been recorded in this ledger yet."
      : deferredSearch.trim()
        ? "No transactions match this search."
        : "No transactions match these filters.";

  return (
    <>
      <FilterRail filters={filters} setFilters={setFilters} busy={result.loading} />

      <div className="register-layout">
        <aside className="account-rail" aria-label="Accounts">
          <button
            type="button"
            className={!filters.accountIds.length ? "account-rail-item account-rail-active" : "account-rail-item"}
            onClick={() => setFilters({ accountIds: [] })}
          >
            <span>All accounts</span>
            <span className="account-rail-balance">
              {formatMoney(openAccounts.reduce((total, account) => total + account.balance, 0))}
            </span>
          </button>
          {openAccounts.map((account) => (
            <button
              key={account.id}
              type="button"
              className={
                filters.accountIds.length === 1 && filters.accountIds[0] === account.id
                  ? "account-rail-item account-rail-active"
                  : "account-rail-item"
              }
              onClick={() => setFilters({ accountIds: [account.id] })}
            >
              <span>{account.name}</span>
              <span className={account.balance < 0 ? "account-rail-balance amount-negative" : "account-rail-balance"}>
                {formatMoney(account.balance)}
              </span>
            </button>
          ))}
        </aside>

        <div className="register-main">
          <div className="report-header">
            <h1>{selectedAccount ? selectedAccount.name : "Transactions"}</h1>
            <div className="headline-row">
              {uncategorisedCount > 0 && !wantsUncategorised && (
                <button
                  type="button"
                  className="uncat-pill"
                  onClick={() => setFilters({ categoryIds: [UNCATEGORISED_CATEGORY_ID] })}
                >
                  {uncategorisedCount} uncategorised
                </button>
              )}
              {wantsUncategorised && (
                <button
                  type="button"
                  className="uncat-pill uncat-pill-active"
                  onClick={() => setFilters({ categoryIds: [] })}
                >
                  Showing uncategorised · clear
                </button>
              )}
              <div className="search-stack">
                <input
                  type="search"
                  name="search"
                  className="search-input"
                  placeholder={
                    selectedAccount ? `Search ${selectedAccount.name}...` : "Search payee, memo, category or account..."
                  }
                  value={search}
                  onChange={(event) => startTransition(() => setSearch(event.target.value))}
                  aria-label="Search transactions"
                />
                <span className="search-meta">
                  Showing {rows.length} of {scopedRows.length} filtered entries
                </span>
              </div>
              {selectedAccount ? (
                <div className="balance-strip">
                  <div className="headline-figure">
                    <span className="figure-label">Cleared balance</span>
                    <span className="figure-value">{formatMoney(selectedAccount.cleared_balance)}</span>
                  </div>
                  <span className="balance-op">+</span>
                  <div className="headline-figure">
                    <span className="figure-label">Uncleared</span>
                    <span className="figure-value">{formatMoney(selectedAccount.uncleared_balance)}</span>
                  </div>
                  <span className="balance-op">=</span>
                  <div className="headline-figure">
                    <span className="figure-label">Working balance</span>
                    <span
                      className={
                        selectedAccount.balance >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"
                      }
                    >
                      {formatMoney(selectedAccount.balance)}
                    </span>
                  </div>
                  <button type="button" className="reconcile-button" onClick={() => setReconciling((value) => !value)}>
                    Reconcile
                  </button>
                </div>
              ) : (
                <>
                  <div className="headline-figure">
                    <span className="figure-label">Money in</span>
                    <span className="figure-value figure-positive">{formatMoney(totals.inflow)}</span>
                  </div>
                  <div className="headline-figure">
                    <span className="figure-label">Money out</span>
                    <span className="figure-value figure-negative">{formatMoney(totals.outflow)}</span>
                  </div>
                  <div className="headline-figure">
                    <span className="figure-label">{rows.length} transactions · net</span>
                    <span className={totals.net >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
                      {formatMoney(totals.net, { sign: true })}
                    </span>
                  </div>
                </>
              )}
            </div>
          </div>

          {reconciling && selectedAccount && (
            <ReconcileStrip
              planId={planId}
              account={selectedAccount}
              onDone={() => {
                setReconciling(false);
                rowsChanged();
              }}
              onCancel={() => setReconciling(false)}
            />
          )}

          {unapproved.length > 0 && (
            <div className="approve-banner">
              <span>
                {unapproved.length} new transaction{unapproved.length === 1 ? "" : "s"} to approve or categorise.
              </span>
              <button type="button" onClick={approveAll} disabled={approving}>
                {approving ? "Approving…" : "Approve all"}
              </button>
            </div>
          )}

          {result.error && (
            <div className="status-panel status-panel-error">
              <p className="status-title">Could not load transactions.</p>
              <p className="status-detail">{result.error}</p>
            </div>
          )}
          {result.loading && !result.data && (
            <div className="status-panel">
              <p className="status-title">Loading transactions...</p>
            </div>
          )}

          {result.data && (
            <section className="report-section">
              <div className="section-heading">
                <button type="button" className="add-transaction-button" onClick={() => setAdding((value) => !value)}>
                  + Add transaction
                </button>
                <span className="section-meta">Click a row to edit · newest first</span>
              </div>
              {rows.length > 0 || adding ? (
                <div className="table-wrap table-wrap-wide">
                  <table className="ledger-table register-table">
                    <thead>
                      <tr>
                        <th>Date</th>
                        {showAccountColumn && <th>Account</th>}
                        <th>Payee</th>
                        <th>Category</th>
                        <th>Memo</th>
                        <th className="num">Outflow</th>
                        <th className="num">Inflow</th>
                        <th className="cleared-cell" title="Cleared status">
                          C
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {adding && (
                        <AddTransactionRow
                          planId={planId}
                          defaultAccountId={selectedAccount?.id}
                          payees={payees.data ?? []}
                          onSaved={rowsChanged}
                          onClose={() => setAdding(false)}
                        />
                      )}
                      {rows.map((txn) =>
                        editingId === txn.id ? (
                          <TransactionEditorRow
                            key={txn.id}
                            transaction={txn}
                            planId={planId}
                            payees={payees.data ?? []}
                            onDone={() => {
                              reload();
                              refresh();
                            }}
                            onCancel={() => setEditingId(null)}
                          />
                        ) : (
                          <RegisterRow
                            key={txn.id}
                            transaction={txn}
                            planId={planId}
                            showAccount={showAccountColumn}
                            onEdit={() => setEditingId(txn.id)}
                            onChanged={rowsChanged}
                          />
                        ),
                      )}
                    </tbody>
                  </table>
                </div>
              ) : (
                <div className="status-panel">
                  <p className="status-title">{emptyMessage}</p>
                  <p className="status-detail">Try widening the date range, clearing filters, or shortening the search term.</p>
                </div>
              )}
            </section>
          )}
        </div>
      </div>
    </>
  );
}
