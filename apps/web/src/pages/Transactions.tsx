import { startTransition, useDeferredValue, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { Transaction } from "../api/types";
import { FilterRail } from "../components/FilterRail";
import { UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import { formatDate } from "../lib/dates";
import { formatAmount, formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

/** True when the row (or any of its split lines) still needs a category. */
function hasUncategorisedLine(txn: Transaction): boolean {
  if (txn.subtransactions?.length) {
    return txn.subtransactions.some((sub) => sub.category_id === null && !sub.transfer_account_id);
  }
  return txn.category_id === null && !txn.transfer_account_id;
}

export function TransactionsPage() {
  const { filters, setFilters } = useFilters();
  const { planId } = usePlan();
  const [params] = useSearchParams();
  const [search, setSearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const flow = params.get("flow");

  const listKey = JSON.stringify({ planId, from: filters.from, to: filters.to });
  const result = useApi(listKey, () =>
    api.transactions(planId, { since_date: filters.from, until_date: filters.to }),
  );

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

  const uncategorisedCount = useMemo(() => inScope.filter(hasUncategorisedLine).length, [inScope]);

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

        return wantsUncategorised && hasUncategorisedLine(txn);
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

  const emptyMessage =
    result.data && result.data.length === 0
      ? "No transactions have been recorded in this ledger yet."
      : deferredSearch.trim()
        ? "No transactions match this search."
        : "No transactions match these filters.";

  return (
    <>
      <FilterRail filters={filters} setFilters={setFilters} busy={result.loading} />
      <div className="report-header">
        <h1>Transactions</h1>
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
            <button type="button" className="uncat-pill uncat-pill-active" onClick={() => setFilters({ categoryIds: [] })}>
              Showing uncategorised · clear
            </button>
          )}
          <div className="search-stack">
            <input
              type="search"
              name="search"
              className="search-input"
              placeholder="Search payee, memo, category or account..."
              value={search}
              onChange={(event) => startTransition(() => setSearch(event.target.value))}
              aria-label="Search transactions"
            />
            <span className="search-meta">
              Showing {rows.length} of {scopedRows.length} filtered entries
            </span>
          </div>
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
        </div>
      </div>

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
            <span className="section-title">Register</span>
            <span className="section-meta">Newest entries first</span>
          </div>
          {rows.length > 0 ? (
            <div className="table-wrap table-wrap-wide">
              <table className="ledger-table register-table">
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Account</th>
                    <th>Payee</th>
                    <th>Category</th>
                    <th>Memo</th>
                    <th className="num">Outflow</th>
                    <th className="num">Inflow</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.flatMap((txn) => [
                    <tr key={txn.id}>
                      <td className="nowrap">{formatDate(txn.date)}</td>
                      <td className="muted">{txn.account_name}</td>
                      <td>{txn.payee_name ?? (txn.transfer_account_id ? "Transfer" : "-")}</td>
                      <td className="muted">
                        {txn.subtransactions?.length
                          ? `Split · ${txn.subtransactions.length} lines`
                          : txn.transfer_account_id
                            ? "Transfer"
                            : (txn.category_name ?? "Uncategorised")}
                      </td>
                      <td className="muted memo-cell" title={txn.memo ?? ""}>
                        {txn.memo ?? "-"}
                      </td>
                      <td className="num amount-negative">{txn.amount < 0 ? formatAmount(txn.amount) : ""}</td>
                      <td className="num amount-positive">{txn.amount > 0 ? formatAmount(txn.amount) : ""}</td>
                    </tr>,
                    ...(txn.subtransactions ?? []).map((sub) => (
                      <tr key={sub.id} className="split-line-row">
                        <td />
                        <td />
                        <td className="muted split-line-cell">↳ {sub.payee_name ?? txn.payee_name ?? "-"}</td>
                        <td className="muted">
                          {sub.transfer_account_id ? "Transfer" : (sub.category_name ?? "Uncategorised")}
                        </td>
                        <td className="muted memo-cell" title={sub.memo ?? ""}>
                          {sub.memo ?? "-"}
                        </td>
                        <td className="num amount-negative">{sub.amount < 0 ? formatAmount(sub.amount) : ""}</td>
                        <td className="num amount-positive">{sub.amount > 0 ? formatAmount(sub.amount) : ""}</td>
                      </tr>
                    )),
                  ])}
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
    </>
  );
}
