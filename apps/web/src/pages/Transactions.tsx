import { startTransition, useDeferredValue, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, useApi } from "../api/client";
import type { Transaction } from "../api/types";
import { FilterRail } from "../components/FilterRail";
import { splitCategoryGroups, UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import { formatDate } from "../lib/dates";
import { decimalToMilli, formatAmount, formatMoney } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

export function TransactionsPage() {
  const { filters, setFilters } = useFilters();
  const { planId } = usePlan();
  const [params] = useSearchParams();
  const [search, setSearch] = useState("");
  const [version, setVersion] = useState(0);
  const [editingId, setEditingId] = useState<string | null>(null);
  const deferredSearch = useDeferredValue(search);
  const flow = params.get("flow");
  const refresh = () => {
    setEditingId(null);
    setVersion((n) => n + 1);
  };

  const listKey = JSON.stringify({ planId, from: filters.from, to: filters.to, version });
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

  const uncategorisedCount = useMemo(
    () =>
      inScope.filter(
        (txn) => txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length,
      ).length,
    [inScope],
  );

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
            <span className="section-meta">Click a row to edit · newest first</span>
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
                  {rows.map((txn) =>
                    editingId === txn.id ? (
                      <TransactionEditorRow
                        key={txn.id}
                        transaction={txn}
                        planId={planId}
                        onDone={refresh}
                        onCancel={() => setEditingId(null)}
                      />
                    ) : (
                      <RegisterRow
                        key={txn.id}
                        transaction={txn}
                        planId={planId}
                        onEdit={() => setEditingId(txn.id)}
                        onChanged={refresh}
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
    </>
  );
}

function RegisterRow({
  transaction: txn,
  planId,
  onEdit,
  onChanged,
}: {
  transaction: Transaction;
  planId: string;
  onEdit: () => void;
  onChanged: () => void;
}) {
  const canQuickCategorise = txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length;
  return (
    <tr className="register-row" onClick={onEdit}>
      <td className="nowrap">{formatDate(txn.date)}</td>
      <td className="muted">{txn.account_name}</td>
      <td>{txn.payee_name ?? (txn.transfer_account_id ? "Transfer" : "-")}</td>
      <td className="muted">
        {txn.subtransactions?.length ? (
          `Split · ${txn.subtransactions.length} lines`
        ) : txn.transfer_account_id ? (
          "Transfer"
        ) : canQuickCategorise ? (
          <QuickCategorySelect planId={planId} transactionId={txn.id} onChanged={onChanged} />
        ) : (
          (txn.category_name ?? "Uncategorised")
        )}
      </td>
      <td className="muted memo-cell" title={txn.memo ?? ""}>
        {txn.memo ?? "-"}
      </td>
      <td className="num amount-negative">{txn.amount < 0 ? formatAmount(txn.amount) : ""}</td>
      <td className="num amount-positive">{txn.amount > 0 ? formatAmount(txn.amount) : ""}</td>
    </tr>
  );
}

/** One-click categorisation straight from the register, without opening the editor. */
function QuickCategorySelect({
  planId,
  transactionId,
  onChanged,
}: {
  planId: string;
  transactionId: string;
  onChanged: () => void;
}) {
  const { categoryGroups } = usePlan();
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const [busy, setBusy] = useState(false);

  return (
    <select
      className="quick-category"
      value=""
      disabled={busy}
      onClick={(event) => event.stopPropagation()}
      onChange={async (event) => {
        const categoryId = event.target.value;
        if (!categoryId) {
          return;
        }
        setBusy(true);
        try {
          await api.updateTransaction(planId, transactionId, { category_id: categoryId });
          onChanged();
        } finally {
          setBusy(false);
        }
      }}
      aria-label="Set category"
    >
      <option value="">{busy ? "Saving…" : "Uncategorised"}</option>
      {[...orderedGroups.primary, ...orderedGroups.quiet].map((group) => (
        <optgroup key={group.id} label={group.name}>
          {group.categories.map((category) => (
            <option key={category.id} value={category.id}>
              {category.name}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}

function TransactionEditorRow({
  transaction: txn,
  planId,
  onDone,
  onCancel,
}: {
  transaction: Transaction;
  planId: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const { accounts, categoryGroups } = usePlan();
  const payees = useApi(`payees-${planId}`, () => api.payees(planId));
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);

  const isTransfer = Boolean(txn.transfer_transaction_id || txn.transfer_account_id);
  const isSplit = Boolean(txn.subtransactions?.length);
  const amountLocked = isTransfer || isSplit;

  const [date, setDate] = useState(txn.date);
  const [accountId, setAccountId] = useState(txn.account_id);
  const [payeeName, setPayeeName] = useState(txn.payee_name ?? "");
  const [categoryId, setCategoryId] = useState(txn.category_id ?? "");
  const [memo, setMemo] = useState(txn.memo ?? "");
  const [cleared, setCleared] = useState(txn.cleared);
  const [direction, setDirection] = useState<"spend" | "income">(txn.amount < 0 ? "spend" : "income");
  const [amount, setAmount] = useState((Math.abs(txn.amount) / 1000).toFixed(2));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const patch: Parameters<typeof api.updateTransaction>[2] = {
        date,
        memo: memo.trim() || null,
        cleared,
      };
      if (!isTransfer) {
        patch.payee_id = null;
        patch.payee_name = payeeName.trim() || null;
      }
      if (!amountLocked) {
        const magnitude = Math.abs(decimalToMilli(amount));
        patch.amount = direction === "spend" ? -magnitude : magnitude;
      }
      if (!isTransfer && !isSplit) {
        patch.category_id = categoryId || null;
      }
      if (accountId !== txn.account_id && !isTransfer) {
        patch.account_id = accountId;
      }
      await api.updateTransaction(planId, txn.id, patch);
      onDone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!window.confirm("Delete this transaction? This cannot be undone from the web app.")) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.deleteTransaction(planId, txn.id);
      onDone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  return (
    <tr className="editor-row">
      <td colSpan={7}>
        <form className="txn-editor" onSubmit={save}>
          <div className="txn-editor-grid">
            <label className="field">
              <span className="field-label">Date</span>
              <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required />
            </label>
            <label className="field">
              <span className="field-label">Account</span>
              <select
                value={accountId}
                onChange={(event) => setAccountId(event.target.value)}
                disabled={isTransfer}
              >
                {accounts
                  .filter((account) => !account.closed || account.id === txn.account_id)
                  .map((account) => (
                    <option key={account.id} value={account.id}>
                      {account.name}
                    </option>
                  ))}
              </select>
            </label>
            <label className="field">
              <span className="field-label">Payee</span>
              <input
                value={payeeName}
                onChange={(event) => setPayeeName(event.target.value)}
                list="editor-payees"
                disabled={isTransfer}
                placeholder={isTransfer ? "Transfer" : "Payee"}
              />
              <datalist id="editor-payees">
                {(payees.data ?? [])
                  .filter((payee) => !payee.deleted)
                  .map((payee) => (
                    <option key={payee.id} value={payee.name} />
                  ))}
              </datalist>
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              {isSplit ? (
                <input value={`Split · ${txn.subtransactions?.length} lines`} disabled />
              ) : (
                <select
                  value={categoryId}
                  onChange={(event) => setCategoryId(event.target.value)}
                  disabled={isTransfer}
                >
                  <option value="">Uncategorised</option>
                  {[...orderedGroups.primary, ...orderedGroups.quiet].map((group) => (
                    <optgroup key={group.id} label={group.name}>
                      {group.categories.map((category) => (
                        <option key={category.id} value={category.id}>
                          {category.name}
                        </option>
                      ))}
                    </optgroup>
                  ))}
                </select>
              )}
            </label>
            <label className="field">
              <span className="field-label">Memo</span>
              <input value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="Note" />
            </label>
            <label className="field">
              <span className="field-label">Amount</span>
              <div className="date-row">
                <div className="segmented" role="group" aria-label="Direction">
                  <button
                    type="button"
                    className={direction === "spend" ? "segment segment-active" : "segment"}
                    disabled={amountLocked}
                    onClick={() => setDirection("spend")}
                  >
                    Out
                  </button>
                  <button
                    type="button"
                    className={direction === "income" ? "segment segment-active" : "segment"}
                    disabled={amountLocked}
                    onClick={() => setDirection("income")}
                  >
                    In
                  </button>
                </div>
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  value={amount}
                  onChange={(event) => setAmount(event.target.value)}
                  disabled={amountLocked}
                  required
                />
              </div>
            </label>
            <label className="field">
              <span className="field-label">Status</span>
              <select value={cleared} onChange={(event) => setCleared(event.target.value)}>
                <option value="uncleared">Uncleared</option>
                <option value="cleared">Cleared</option>
                <option value="reconciled">Reconciled</option>
              </select>
            </label>
          </div>

          {isTransfer && (
            <p className="field-note">
              This entry is one side of a transfer; the account, payee, category, and amount stay linked to the other
              side.
            </p>
          )}
          {isSplit && (
            <p className="field-note">Split amounts and categories are preserved as imported; edit the shared fields here.</p>
          )}
          {error && (
            <div className="status-panel status-panel-error compact-panel">
              <p className="status-title">Could not save.</p>
              <p className="status-detail">{error}</p>
            </div>
          )}

          <div className="txn-editor-actions">
            <button type="submit" disabled={busy}>
              {busy ? "Saving…" : "Save changes"}
            </button>
            <button type="button" className="text-button" onClick={onCancel} disabled={busy}>
              Cancel
            </button>
            {!isTransfer && (
              <button type="button" className="text-button danger" onClick={remove} disabled={busy}>
                Delete
              </button>
            )}
          </div>
        </form>
      </td>
    </tr>
  );
}
