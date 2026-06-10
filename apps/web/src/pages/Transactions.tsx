import { useMemo, useState } from "react";
import { api, useApi } from "../api/client";
import { FilterRail } from "../components/FilterRail";
import { formatDate } from "../lib/dates";
import { formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

export function TransactionsPage() {
  const { filters, setFilters } = useFilters();
  const { planId } = usePlan();
  const [search, setSearch] = useState("");

  const listKey = JSON.stringify({ planId, from: filters.from, to: filters.to });
  const result = useApi(listKey, () =>
    api.transactions(planId, { since_date: filters.from, until_date: filters.to }),
  );

  const rows = useMemo(() => {
    if (!result.data) {
      return [];
    }
    const needle = search.trim().toLowerCase();
    return result.data
      .filter((txn) => !txn.deleted)
      .filter((txn) => !filters.accountIds.length || filters.accountIds.includes(txn.account_id))
      .filter(
        (txn) =>
          !filters.categoryIds.length ||
          (txn.category_id !== null && filters.categoryIds.includes(txn.category_id)) ||
          txn.subtransactions?.some(
            (sub) => sub.category_id !== null && filters.categoryIds.includes(sub.category_id),
          ),
      )
      .filter(
        (txn) =>
          !needle ||
          txn.payee_name?.toLowerCase().includes(needle) ||
          txn.memo?.toLowerCase().includes(needle) ||
          txn.category_name?.toLowerCase().includes(needle),
      )
      .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));
  }, [result.data, filters.accountIds, filters.categoryIds, search]);

  const total = rows.reduce((sum, txn) => sum + txn.amount, 0);

  return (
    <>
      <FilterRail filters={filters} setFilters={setFilters} busy={result.loading} />
      <div className="report-header">
        <h1>Transactions</h1>
        <div className="headline-row">
          <input
            type="search"
            name="search"
            className="search-input"
            placeholder="Search payee, memo or category…"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            aria-label="Search transactions"
          />
          <div className="headline-figure">
            <span className="figure-label">{rows.length} transactions · net</span>
            <span className={total >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {formatMoney(total, { sign: true })}
            </span>
          </div>
        </div>
      </div>

      {result.error && <p className="error-note">{result.error}</p>}
      {result.loading && !result.data && <p className="loading-note">Loading…</p>}

      {result.data && (
        <div className="table-scroll">
        <table className="ledger-table register-table">
          <thead>
            <tr>
              <th>Date</th>
              <th>Account</th>
              <th>Payee</th>
              <th>Category</th>
              <th>Memo</th>
              <th className="num">Amount</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((txn) => (
              <tr key={txn.id}>
                <td className="nowrap">{formatDate(txn.date)}</td>
                <td className="muted">{txn.account_name}</td>
                <td>{txn.payee_name ?? "—"}</td>
                <td className="muted">
                  {txn.subtransactions?.length
                    ? "Split"
                    : txn.transfer_account_id
                      ? "Transfer"
                      : (txn.category_name ?? "Uncategorised")}
                </td>
                <td className="muted memo-cell">{txn.memo}</td>
                <td className={txn.amount < 0 ? "num amount-negative" : "num amount-positive"}>
                  {formatMoney(txn.amount)}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="empty-row">
                  No transactions match these filters.
                </td>
              </tr>
            )}
          </tbody>
        </table>
        </div>
      )}
    </>
  );
}
