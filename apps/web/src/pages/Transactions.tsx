import { startTransition, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { NavLink, useSearchParams } from "react-router-dom";
import { ApiError, api, useApi } from "../api/client";
import type {
  Account,
  AccountReconciliationPreview,
  AccountReconciliationResult,
  CategoryGroup,
  Payee,
  ReconciliationMismatchDetail,
  Transaction,
  TransactionUpdateInput,
} from "../api/types";
import { CategorySelect } from "../components/CategorySelect";
import { FilterRail } from "../components/FilterRail";
import { splitCategoryGroups, UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import { formatDate, todayIso } from "../lib/dates";
import { stableHash } from "../lib/hash";
import { formatAmount, formatMilliunitsInput, formatMoney, parseMilliunits } from "../lib/money";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

/** True when the row (or any of its split lines) still needs a category. */
function hasUncategorisedLine(txn: Transaction): boolean {
  if (txn.subtransactions?.length) {
    return txn.subtransactions.some((sub) => sub.category_id === null && !sub.transfer_account_id);
  }
  return txn.category_id === null && !txn.transfer_account_id;
}

type ReconcileDraft = {
  accountId: string;
  statementDate: string;
  statementBalance: string;
  operationSeed: string;
  reviewReady: boolean;
  confirmationChecked: boolean;
  mismatch: ReconciliationMismatchDetail | null;
};

export function TransactionsPage() {
  const { filters, setFilters } = useFilters();
  const { accounts, categoryGroups, planId, reload } = usePlan();
  const payees = useApi(planId, () => api.payees(planId));
  const [params] = useSearchParams();
  const [search, setSearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const flow = params.get("flow");
  const selectedAccount = filters.accountIds.length === 1
    ? accounts.find((account) => account.id === filters.accountIds[0])
    : undefined;
  const visibleAccounts = useMemo(
    () => filters.accountIds.length
      ? accounts.filter((account) => filters.accountIds.includes(account.id))
      : accounts,
    [accounts, filters.accountIds],
  );
  const registerAccountIds = useMemo(() => new Set(visibleAccounts.map((account) => account.id)), [visibleAccounts]);
  // “All Accounts” includes archived ledger rows, but its cash-on-hand
  // headline remains an active-account balance rather than resurrecting
  // balances from closed accounts.
  const balanceAccounts = useMemo(
    () => filters.accountIds.length ? visibleAccounts : visibleAccounts.filter((account) => !account.closed),
    [filters.accountIds.length, visibleAccounts],
  );
  const usesActiveBalanceScope = filters.accountIds.length === 0;
  const registerLabel = filters.accountIds.length === 0
    ? "All Accounts"
    : selectedAccount?.name
      ?? (filters.accountIds.length === 1 ? "Account unavailable" : "Selected Accounts");
  const balances = balanceAccounts.reduce(
    (summary, account) => ({
      cleared: summary.cleared + account.cleared_balance,
      uncleared: summary.uncleared + account.uncleared_balance,
      working: summary.working + account.balance,
    }),
    { cleared: 0, uncleared: 0, working: 0 },
  );

  const listKey = JSON.stringify({
    planId,
    from: filters.from,
    to: filters.to,
    accountIds: filters.accountIds,
    categoryIds: filters.categoryIds,
    flow,
  });
  const [refreshGeneration, setRefreshGeneration] = useState(0);
  const requestVersionRef = useRef(0);
  const pageQuery = useMemo(
    () => ({ since_date: filters.from, until_date: filters.to, limit: 100 }),
    [filters.from, filters.to],
  );
  const [page, setPage] = useState({
    transactions: [] as Transaction[],
    hasMore: false,
    nextOffset: null as number | null,
    loading: true,
    loadingMore: false,
    loaded: false,
    error: null as string | null,
  });
  const [editing, setEditing] = useState<Transaction | null>(null);
  const [pendingDeletion, setPendingDeletion] = useState<Transaction | null>(null);
  const [reconcileDraft, setReconcileDraft] = useState<ReconcileDraft | null>(null);
  const [reconciliationPreviewGeneration, setReconciliationPreviewGeneration] = useState(0);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [mutationSuccess, setMutationSuccess] = useState<string | null>(null);
  const [mutatingId, setMutatingId] = useState<string | null>(null);
  const mutationLockRef = useRef(false);
  const selectedAccountId = filters.accountIds.length === 1 ? filters.accountIds[0]! : null;
  const reconciliationPreviewInput = reconcileDraft?.reviewReady && reconcileDraft.accountId && reconcileDraft.statementDate
    ? { accountId: reconcileDraft.accountId, statementDate: reconcileDraft.statementDate }
    : null;
  const reconciliationPreview = useApi<AccountReconciliationPreview | null>(
    reconciliationPreviewInput
      ? `${planId}:${reconciliationPreviewInput.accountId}:${reconciliationPreviewInput.statementDate}:${reconciliationPreviewGeneration}`
      : "reconciliation-preview-idle",
    () => reconciliationPreviewInput
      ? api.accountReconciliation(planId, reconciliationPreviewInput.accountId, reconciliationPreviewInput.statementDate)
      : Promise.resolve(null),
  );

  const fetchTransactionPage = (offset: number) => selectedAccountId
    ? api.accountTransactions(planId, selectedAccountId, { ...pageQuery, offset })
    : api.transactions(planId, { ...pageQuery, offset });

  /**
   * Offset pagination is only stable while the ledger is unchanged. Invalidate
   * all pending requests and start again after a write so no older row is
   * skipped (or a transfer mirror is left stale) in the visible register.
   */
  const refreshFirstPage = () => {
    requestVersionRef.current += 1;
    setPage({ transactions: [], hasMore: false, nextOffset: null, loading: true, loadingMore: false, loaded: false, error: null });
    setRefreshGeneration((generation) => generation + 1);
  };

  useEffect(() => {
    let cancelled = false;
    const requestVersion = ++requestVersionRef.current;
    setPage({ transactions: [], hasMore: false, nextOffset: null, loading: true, loadingMore: false, loaded: false, error: null });
    fetchTransactionPage(0)
      .then((first) => {
        if (!cancelled && requestVersion === requestVersionRef.current) {
          setPage({
            transactions: first.transactions,
            hasMore: first.has_more,
            nextOffset: first.next_offset,
            loading: false,
            loadingMore: false,
            loaded: true,
            error: null,
          });
        }
      })
      .catch((error: Error) => {
        if (!cancelled && requestVersion === requestVersionRef.current) {
          setPage({ transactions: [], hasMore: false, nextOffset: null, loading: false, loadingMore: false, loaded: false, error: error.message });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [listKey, refreshGeneration]);

  const loadOlder = async () => {
    if (page.loadingMore || !page.hasMore || page.nextOffset === null) return;
    const requestedOffset = page.nextOffset;
    const requestVersion = requestVersionRef.current;
    setPage((current) => ({ ...current, loadingMore: true, error: null }));
    try {
      const older = await fetchTransactionPage(requestedOffset);
      setPage((current) => requestVersion !== requestVersionRef.current || current.nextOffset !== requestedOffset
        ? current
        : {
            ...current,
            transactions: [...current.transactions, ...older.transactions.filter((transaction) => !current.transactions.some((loaded) => loaded.id === transaction.id))],
            hasMore: older.has_more,
            nextOffset: older.next_offset,
            loadingMore: false,
            error: null,
          });
    } catch (error) {
      setPage((current) => requestVersion !== requestVersionRef.current || current.nextOffset !== requestedOffset
        ? current
        : { ...current, loadingMore: false, error: (error as Error).message });
    }
  };

  const saveTransaction = async (transactionId: string, input: TransactionUpdateInput) => {
    if (mutationLockRef.current) return;
    mutationLockRef.current = true;
    requestVersionRef.current += 1;
    setMutatingId(transactionId);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await api.updateTransaction(planId, transactionId, input);
      setEditing(null);
      reload();
      refreshFirstPage();
      setReconciliationPreviewGeneration((generation) => generation + 1);
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
      refreshFirstPage();
    } finally {
      mutationLockRef.current = false;
      setMutatingId(null);
    }
  };

  const toggleCleared = async (transaction: Transaction) => {
    if (mutationLockRef.current || (transaction.cleared !== "uncleared" && transaction.cleared !== "cleared")) return;
    const cleared = transaction.cleared === "cleared" ? "uncleared" : "cleared";
    mutationLockRef.current = true;
    requestVersionRef.current += 1;
    setMutatingId(transaction.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await api.updateTransactionCleared(planId, transaction.id, transaction.cleared, cleared);
      reload();
      refreshFirstPage();
      setReconciliationPreviewGeneration((generation) => generation + 1);
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
      refreshFirstPage();
      reload();
    } finally {
      mutationLockRef.current = false;
      setMutatingId(null);
    }
  };

  const deleteTransaction = async (transaction: Transaction) => {
    if (mutationLockRef.current) return;
    mutationLockRef.current = true;
    requestVersionRef.current += 1;
    setMutatingId(transaction.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await api.deleteTransaction(planId, transaction.id);
      if (editing?.id === transaction.id) {
        setEditing(null);
      }
      setPendingDeletion(null);
      reload();
      refreshFirstPage();
      setReconciliationPreviewGeneration((generation) => generation + 1);
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
      refreshFirstPage();
    } finally {
      mutationLockRef.current = false;
      setMutatingId(null);
    }
  };

  const openReconcile = () => {
    setReconcileDraft({
      accountId: selectedAccount?.id ?? "",
      statementDate: todayIso(),
      statementBalance: "",
      operationSeed: crypto.randomUUID(),
      reviewReady: false,
      confirmationChecked: false,
      mismatch: null,
    });
    setMutationError(null);
    setMutationSuccess(null);
    setReconciliationPreviewGeneration((generation) => generation + 1);
  };

  const updateReconcile = (patch: Partial<ReconcileDraft>) => {
    setReconcileDraft((current) => current
      ? {
          ...current,
          ...patch,
          reviewReady: false,
          confirmationChecked: false,
          mismatch: null,
        }
      : current);
    setMutationError(null);
    setMutationSuccess(null);
    setReconciliationPreviewGeneration((generation) => generation + 1);
  };

  const reviewReconciliation = () => {
    if (!reconcileDraft) return;
    const statementBalance = parseMilliunits(reconcileDraft.statementBalance);
    if (!reconcileDraft.accountId) {
      setMutationError("Choose the account you want to reconcile.");
      return;
    }
    if (!reconcileDraft.statementDate) {
      setMutationError("Choose the statement date.");
      return;
    }
    if (statementBalance === null) {
      setMutationError("Enter the exact statement balance with no more than three decimal places.");
      return;
    }
    setMutationError(null);
    setMutationSuccess(null);
    setReconcileDraft((current) => current ? { ...current, reviewReady: true, mismatch: null } : current);
    setReconciliationPreviewGeneration((generation) => generation + 1);
  };

  const submitReconciliation = async () => {
    if (!reconcileDraft) return;
    const statementBalance = parseMilliunits(reconcileDraft.statementBalance);
    if (statementBalance === null) {
      setMutationError("Enter the exact statement balance with no more than three decimal places.");
      return;
    }
    const preview = reconciliationPreviewData;
    const difference = preview ? statementBalance - preview.projected_reconciled_balance : null;
    if (!reconcileDraft.reviewReady || !reconcileDraft.confirmationChecked || reconciliationPreview.loading || reconciliationPreview.error || difference !== 0) {
      setMutationError("Wait for a matching reconciliation preview, then confirm it before continuing.");
      return;
    }
    if (mutationLockRef.current) return;

    const mutationId = `reconcile:${reconcileDraft.accountId}`;
    mutationLockRef.current = true;
    requestVersionRef.current += 1;
    setMutatingId(mutationId);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      const result = await api.reconcileAccount(
        planId,
        reconcileDraft.accountId,
        reconcileDraft.statementDate,
        statementBalance,
        reconciliationKey(reconcileDraft.accountId, reconcileDraft.statementDate, statementBalance, reconcileDraft.operationSeed),
      );
      setReconcileDraft(null);
      reload();
      refreshFirstPage();
      setMutationSuccess(reconciliationSuccess(result));
    } catch (cause) {
      refreshFirstPage();
      if (cause instanceof ApiError && cause.status === 409 && cause.code === "reconciliation_mismatch" && isReconciliationMismatchDetail(cause.detail)) {
        const mismatch = cause.detail;
        setReconcileDraft((current) => current ? { ...current, mismatch } : current);
        setReconciliationPreviewGeneration((generation) => generation + 1);
        setMutationError(null);
      } else {
        setMutationError(cause instanceof Error ? cause.message : String(cause));
      }
    } finally {
      mutationLockRef.current = false;
      setMutatingId(null);
    }
  };

  const wantsUncategorised = filters.categoryIds.includes(UNCATEGORISED_CATEGORY_ID);
  const categoryIds = useMemo(
    () => new Set(filters.categoryIds.filter((categoryId) => categoryId !== UNCATEGORISED_CATEGORY_ID)),
    [filters.categoryIds],
  );

  const inScope = useMemo(
    () =>
      page.transactions
        .filter((txn) => !txn.deleted)
        .filter((txn) => registerAccountIds.has(txn.account_id)),
    [page.transactions, registerAccountIds],
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
    page.loaded && page.transactions.length === 0
      ? "No transactions have been recorded in this ledger yet."
      : deferredSearch.trim()
        ? "No transactions match this search."
        : "No transactions match these filters.";
  const mutationBusy = Boolean(mutatingId);
  const reconciliationBusy = mutationBusy;
  const reviewedStatementBalance = reconcileDraft ? parseMilliunits(reconcileDraft.statementBalance) : null;
  // `useApi` intentionally keeps its previous response while a new key starts
  // loading. Never allow that response to authorise a different draft.
  const reconciliationPreviewData = reconciliationPreview.data
    && reconcileDraft
    && reconciliationPreview.data.account.id === reconcileDraft.accountId
    && reconciliationPreview.data.statement_date === reconcileDraft.statementDate
    ? reconciliationPreview.data
    : null;
  const reconciliationDifference = reconciliationPreviewData && reviewedStatementBalance !== null
    ? reviewedStatementBalance - reconciliationPreviewData.projected_reconciled_balance
    : null;
  const reconciliationCanConfirm = Boolean(
    reconcileDraft?.reviewReady
      && reconcileDraft.confirmationChecked
      && reconciliationPreviewData
      && !reconciliationPreview.loading
      && !reconciliationPreview.error
      && reconciliationDifference === 0,
  );

  return (
    <>
      <FilterRail filters={filters} setFilters={setFilters} busy={page.loading || page.loadingMore} />
      <div className="report-header">
        <div>
          <span className="page-eyebrow">{usesActiveBalanceScope ? "All account history" : "Account register"}</span>
          <h1>{registerLabel}</h1>
        </div>
        <div className="headline-row register-balances">
          <div className="headline-figure">
            <span className="figure-value">{formatMoney(balances.cleared)}</span>
            <span className="figure-label">{usesActiveBalanceScope ? "Active cleared balance" : "Cleared balance"}</span>
          </div>
          <span className="balance-operator" aria-hidden="true">+</span>
          <div className="headline-figure">
            <span className={balances.uncleared >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {formatMoney(balances.uncleared)}
            </span>
            <span className="figure-label">{usesActiveBalanceScope ? "Active uncleared balance" : "Uncleared balance"}</span>
          </div>
          <span className="balance-operator" aria-hidden="true">=</span>
          <div className="headline-figure">
            <span className={balances.working >= 0 ? "figure-value figure-positive" : "figure-value figure-negative"}>
              {formatMoney(balances.working)}
            </span>
            <span className="figure-label">{usesActiveBalanceScope ? "Active working balance" : "Working balance"}</span>
          </div>
        </div>
      </div>
      <div className="register-toolbar">
        <div className="register-toolbar-actions">
          <NavLink to="/add" className="register-add-link">+ Add transaction</NavLink>
          <button
            type="button"
            className="register-add-link register-secondary-action"
            onClick={openReconcile}
            disabled={Boolean(mutatingId)}
          >
            Reconcile account
          </button>
        </div>
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
              Showing {rows.length} of {scopedRows.length} loaded filtered entries
            </span>
            {filters.accountIds.length > 1 && page.hasMore && (
              <span className="search-meta">Load older entries to extend this multi-account result.</span>
            )}
          </div>
        </div>
      </div>

      {page.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load {page.loaded ? "older " : ""}transactions.</p>
          <p className="status-detail">{page.error}</p>
        </div>
      )}
      {mutationError && (
        <div className="status-panel status-panel-error compact-panel" role="alert">
          <p className="status-title">{reconcileDraft ? "Could not prepare this reconciliation." : "Could not update this transaction."}</p>
          <p className="status-detail">{mutationError}</p>
        </div>
      )}
      {mutationSuccess && (
        <div className="status-panel status-panel-success compact-panel" role="status">
          <p className="status-title">{mutationSuccess}</p>
        </div>
      )}
      {reconcileDraft && (
        <section className="transaction-editor reconcile-editor" aria-labelledby="reconcile-account-heading">
          <div className="section-heading">
            <div>
              <span className="section-title" id="reconcile-account-heading">Reconcile account</span>
              <span className="section-meta">
                Choose the account, statement date, and exact statement balance before you confirm the reconciliation.
              </span>
            </div>
            <button
              type="button"
              className="text-button"
              onClick={() => {
                setReconcileDraft(null);
                setMutationError(null);
              }}
              disabled={reconciliationBusy}
            >
              Cancel
            </button>
          </div>
          <div className="transaction-editor-form">
            <div className="field-row reconcile-grid">
              <label className="field">
                <span className="field-label">Account</span>
                <select
                  value={reconcileDraft.accountId}
                  onChange={(event) => updateReconcile({ accountId: event.target.value })}
                  disabled={reconciliationBusy}
                  required
                >
                  <option value="">Choose account</option>
                  {accounts.map((account) => (
                    <option key={account.id} value={account.id}>
                      {account.name}
                      {account.closed ? " (closed)" : ""}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span className="field-label">Statement date</span>
                <input
                  type="date"
                  value={reconcileDraft.statementDate}
                  onChange={(event) => updateReconcile({ statementDate: event.target.value })}
                  disabled={reconciliationBusy}
                  required
                />
              </label>
              <label className="field">
                <span className="field-label">Statement balance</span>
                <input
                  type="text"
                  inputMode="decimal"
                  placeholder="0.000"
                  value={reconcileDraft.statementBalance}
                  onChange={(event) => updateReconcile({ statementBalance: event.target.value })}
                  disabled={reconciliationBusy}
                  required
                />
                <span className="field-note">Enter the exact balance shown on the statement, using up to three decimal places.</span>
              </label>
            </div>

            <p className="diagnostic-note">
              Every cleared transaction dated on or before {reconcileDraft.statementDate ? formatDate(reconcileDraft.statementDate) : "the statement date"} becomes reconciled.
              Uncleared transactions and later cleared transactions stay unchanged.
            </p>

            {reconcileDraft.reviewReady && (
              <div className="reconcile-review" aria-live="polite">
                {reconciliationPreview.loading ? (
                  <p className="diagnostic-note">Loading the latest reconciliation preview…</p>
                ) : reconciliationPreview.error ? (
                  <div className="status-panel status-panel-error compact-panel" role="alert">
                    <p className="status-title">Could not load the reconciliation preview.</p>
                    <p className="status-detail">{reconciliationPreview.error}</p>
                  </div>
                ) : reconciliationPreviewData && reviewedStatementBalance !== null ? (
                  <>
                    <div className="reconcile-review-grid">
                      <ReviewFigure label="Account" value={reconciliationPreviewData.account.name} />
                      <ReviewFigure label="Statement date" value={formatDate(reconciliationPreviewData.statement_date)} />
                      <ReviewFigure label="Current reconciled balance" value={formatMoney(reconciliationPreviewData.current_reconciled_balance, { sign: reconciliationPreviewData.current_reconciled_balance > 0 })} />
                      <ReviewFigure label="Projected reconciled balance" value={formatMoney(reconciliationPreviewData.projected_reconciled_balance, { sign: reconciliationPreviewData.projected_reconciled_balance > 0 })} />
                      <ReviewFigure label="Cleared candidates" value={String(reconciliationPreviewData.candidate_transaction_count)} />
                      <ReviewFigure label="Statement balance" value={formatMoney(reviewedStatementBalance, { sign: reviewedStatementBalance > 0 })} />
                      <ReviewFigure label="Difference" value={formatMoney(reconciliationDifference ?? 0, { sign: true })} tone={reconciliationDifference === 0 ? undefined : "negative"} />
                    </div>
                    {reconciliationDifference !== 0 && (
                      <p className="diagnostic-note">The statement balance must match the projected reconciled balance before this can be confirmed.</p>
                    )}
                    <label className="transaction-editor-checkbox reconcile-confirmation">
                      <input
                        type="checkbox"
                        checked={reconcileDraft.confirmationChecked}
                        onChange={(event) => setReconcileDraft((current) => current ? { ...current, confirmationChecked: event.target.checked } : current)}
                        disabled={reconciliationBusy || reconciliationDifference !== 0}
                      />
                      I understand that cleared transactions through this date will be locked in as reconciled.
                    </label>
                  </>
                ) : null}
              </div>
            )}

            {reconcileDraft.mismatch && (
              <div className="status-panel status-panel-error reconcile-mismatch" role="alert">
                <p className="status-title">The statement balance does not match the reconciled ledger total.</p>
                <p className="status-detail">
                  Update the cleared transactions on or before {formatDate(reconcileDraft.statementDate)} or correct the statement balance, then try again.
                </p>
                <div className="reconcile-review-grid reconcile-review-grid-mismatch">
                  <ReviewFigure label="Already reconciled" value={formatMoney(reconcileDraft.mismatch.current_reconciled_balance)} />
                  <ReviewFigure label="Projected after this reconciliation" value={formatMoney(reconcileDraft.mismatch.projected_reconciled_balance, { sign: reconcileDraft.mismatch.projected_reconciled_balance > 0 })} />
                  <ReviewFigure label="Statement balance" value={formatMoney(reconcileDraft.mismatch.statement_balance, { sign: reconcileDraft.mismatch.statement_balance > 0 })} />
                  <ReviewFigure label="Off by" value={formatMoney(reconcileDraft.mismatch.difference, { sign: true })} tone={reconcileDraft.mismatch.difference === 0 ? undefined : "negative"} />
                </div>
              </div>
            )}

            <div className="transaction-editor-actions">
              <button
                type="button"
                className="text-button"
                onClick={() => {
                  setReconcileDraft(null);
                  setMutationError(null);
                }}
                disabled={reconciliationBusy}
              >
                Cancel
              </button>
              {!reconcileDraft.reviewReady ? (
                <button type="button" className="save-button" onClick={reviewReconciliation} disabled={reconciliationBusy}>
                  Review reconciliation
                </button>
              ) : (
                <button
                  type="button"
                  className="save-button"
                  onClick={() => void submitReconciliation()}
                  disabled={reconciliationBusy || !reconciliationCanConfirm}
                >
                  {reconciliationBusy ? "Reconciling…" : "Confirm reconciliation"}
                </button>
              )}
            </div>
          </div>
        </section>
      )}
      {pendingDeletion && (
        <section className="transaction-delete-confirm" role="region" aria-labelledby="delete-transaction-heading">
          <div>
            <h2 id="delete-transaction-heading">Delete transaction?</h2>
            <p id="delete-transaction-detail">
              {pendingDeletion.payee_name ?? (pendingDeletion.transfer_account_id ? "This transfer" : "This transaction")} will be removed from HowMuch.
              {pendingDeletion.transfer_transaction_id ? " Its linked transfer entry will also be removed." : ""}
            </p>
          </div>
          <div className="transaction-delete-confirm-actions">
            <button type="button" className="text-button" onClick={() => setPendingDeletion(null)} disabled={mutationBusy}>Cancel</button>
            <button type="button" className="transaction-delete-button" onClick={() => void deleteTransaction(pendingDeletion)} disabled={mutationBusy}>
              {mutatingId === pendingDeletion.id ? "Deleting..." : "Delete transaction"}
            </button>
          </div>
        </section>
      )}
      {editing && (
        <TransactionEditor
          transaction={editing}
          payees={payees.data ?? []}
          categoryGroups={categoryGroups}
          accounts={accounts}
          saving={mutatingId === editing.id}
          disabled={mutationBusy}
          onCancel={() => {
            setEditing(null);
            setMutationError(null);
          }}
          onSave={saveTransaction}
        />
      )}
      {page.loading && !page.loaded && (
        <div className="status-panel">
          <p className="status-title">Loading transactions...</p>
        </div>
      )}

      {page.loaded && (
        <section className="report-section">
          <div className="section-heading">
            <span className="section-title">Register</span>
            <span className="section-meta">
              {rows.length} transactions · {formatMoney(totals.inflow)} in · {formatMoney(totals.outflow)} out · {formatMoney(totals.net, { sign: true })} net
            </span>
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
                    <th className="register-actions-heading"><span className="sr-only">Actions</span></th>
                    <th className="register-status-heading"><span className="sr-only">Cleared status</span></th>
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
                      <td className="register-actions">
                        <button
                          type="button"
                          className="register-row-action"
                          onClick={() => {
                            setEditing(txn);
                            setMutationError(null);
                          }}
                          disabled={Boolean(mutatingId)}
                          aria-label={`Edit ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                        >
                          Edit
                        </button>
                        <button
                          type="button"
                          className="register-row-action register-row-action-danger"
                          onClick={() => {
                            setPendingDeletion(txn);
                            setMutationError(null);
                          }}
                          disabled={Boolean(mutatingId)}
                          aria-label={`Delete ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                        >
                          Delete
                        </button>
                      </td>
                      <td className="register-status">
                        <ClearedStatus
                          transaction={txn}
                          busy={Boolean(mutatingId)}
                          onToggle={() => void toggleCleared(txn)}
                        />
                      </td>
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
                        <td />
                        <td />
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
          {page.hasMore && (
            <div className="register-load-more">
              <button type="button" className="register-load-more-button" onClick={loadOlder} disabled={page.loadingMore}>
                {page.loadingMore ? "Loading older transactions…" : "Load older transactions"}
              </button>
            </div>
          )}
        </section>
      )}
    </>
  );
}

function ClearedStatus({
  transaction,
  busy,
  onToggle,
}: {
  transaction: Transaction;
  busy: boolean;
  onToggle: () => void;
}) {
  if (transaction.cleared === "reconciled") {
    return (
      <span className="cleared-status cleared-status-reconciled" aria-label="Reconciled" title="Reconciled">
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <path d="M6.5 8V6a3.5 3.5 0 0 1 7 0v2M5 8h10v8H5z" />
        </svg>
      </span>
    );
  }

  const cleared = transaction.cleared === "cleared";
  const payee = transaction.payee_name ?? (transaction.transfer_account_id ? "transfer" : "transaction");
  return (
    <button
      type="button"
      className={`cleared-status cleared-status-toggle${cleared ? " cleared-status-cleared" : ""}`}
      onClick={onToggle}
      disabled={busy}
      aria-pressed={cleared}
      aria-label={`Mark ${payee} on ${formatDate(transaction.date)} ${cleared ? "uncleared" : "cleared"}`}
      title={cleared ? "Cleared — click to mark uncleared" : "Uncleared — click to mark cleared"}
    >
      <span aria-hidden="true">{cleared ? "C✓" : "C"}</span>
    </button>
  );
}

function ReviewFigure({ label, value, tone }: { label: string; value: string; tone?: "negative" }) {
  return (
    <div className="reconcile-figure">
      <span className="figure-label">{label}</span>
      <span className={tone === "negative" ? "figure-value figure-negative" : "figure-value"}>{value}</span>
    </div>
  );
}

type SplitDraft = {
  id: string;
  amount: string;
  payeeId: string | null;
  originalPayeeName: string;
  payeeName: string;
  categoryId: string;
  memo: string;
  transferAccountId: string | null;
  transferTransactionId: string | null;
};

function isReconciliationMismatchDetail(value: unknown): value is ReconciliationMismatchDetail {
  if (!value || typeof value !== "object") {
    return false;
  }
  const detail = value as Record<string, unknown>;
  return typeof detail.current_reconciled_balance === "number"
    && typeof detail.projected_reconciled_balance === "number"
    && typeof detail.statement_balance === "number"
    && typeof detail.difference === "number";
}

function reconciliationKey(accountId: string, statementDate: string, statementBalance: number, seed: string): string {
  return `reconcile-${seed}-${stableHash(`${accountId}:${statementDate}:${statementBalance}`)}`;
}

function reconciliationSuccess(result: AccountReconciliationResult): string {
  const accountName = result.account?.name ?? "account";
  const count = result.reconciled_transaction_count;
  return `${accountName} reconciled through ${formatDate(result.statement_date)}. ${count} cleared transaction${count === 1 ? "" : "s"} matched ${formatMoney(result.statement_balance)}.`;
}

function payeeInput(name: string, originalId: string | null, originalName: string, payees: Payee[]): Pick<TransactionUpdateInput, "payee_id" | "payee_name"> {
  const trimmed = name.trim();
  if (!trimmed) {
    return { payee_id: null, payee_name: null };
  }
  if (trimmed === originalName && originalId) {
    return { payee_id: originalId, payee_name: trimmed };
  }
  const matched = payees.find((payee) => !payee.deleted && !payee.transfer_account_id && payee.name === trimmed);
  return { payee_id: matched?.id ?? null, payee_name: trimmed };
}

function TransactionEditor({
  transaction,
  payees,
  categoryGroups,
  accounts,
  saving,
  disabled,
  onCancel,
  onSave,
}: {
  transaction: Transaction;
  payees: Payee[];
  categoryGroups: CategoryGroup[];
  accounts: Account[];
  saving: boolean;
  disabled: boolean;
  onCancel: () => void;
  onSave: (transactionId: string, input: TransactionUpdateInput) => Promise<void>;
}) {
  const isSplit = Boolean(transaction.subtransactions?.length);
  const isTransfer = Boolean(transaction.transfer_account_id);
  const direction = transaction.amount < 0 ? -1 : 1;
  const [date, setDate] = useState(transaction.date);
  const [amount, setAmount] = useState(formatMilliunitsInput(Math.abs(transaction.amount)));
  const [payeeName, setPayeeName] = useState(transaction.payee_name ?? "");
  const [categoryId, setCategoryId] = useState(transaction.category_id ?? "");
  const [memo, setMemo] = useState(transaction.memo ?? "");
  const [approved, setApproved] = useState(transaction.approved);
  const [flagColor, setFlagColor] = useState(transaction.flag_color ?? "");
  const [validationError, setValidationError] = useState<string | null>(null);
  const [splitLines, setSplitLines] = useState<SplitDraft[]>(() => (transaction.subtransactions ?? []).map((line) => ({
    id: line.id,
    amount: formatMilliunitsInput(line.amount),
    payeeId: line.payee_id,
    originalPayeeName: line.payee_name ?? "",
    payeeName: line.payee_name ?? "",
    categoryId: line.category_id ?? "",
    memo: line.memo ?? "",
    transferAccountId: line.transfer_account_id ?? null,
    transferTransactionId: line.transfer_transaction_id ?? null,
  })));
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const transferTarget = accounts.find((account) => account.id === transaction.transfer_account_id)?.name ?? "linked account";
  const parentAmount = parseMilliunits(amount);
  const splitTotal = splitLines.reduce((total, line) => total + (parseMilliunits(line.amount) ?? 0), 0);

  const updateSplit = (id: string, patch: Partial<SplitDraft>) => {
    setValidationError(null);
    setSplitLines((lines) => lines.map((line) => line.id === id ? { ...line, ...patch } : line));
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    const parsedAmount = parseMilliunits(amount);
    if (parsedAmount === null || parsedAmount < 0) {
      setValidationError("Enter zero or a positive amount.");
      return;
    }
    const signedAmount = direction * parsedAmount;
    const input: TransactionUpdateInput = {
      date,
      amount: signedAmount,
      memo: memo.trim() || null,
      approved,
      flag_color: flagColor || null,
    };

    if (isSplit) {
      const parsedLines = splitLines.map((line) => ({ line, amount: parseMilliunits(line.amount) }));
      if (parsedLines.some((item) => item.amount === null)) {
        setValidationError("Every split line needs a valid signed amount.");
        return;
      }
      if (parsedLines.reduce((total, item) => total + (item.amount ?? 0), 0) !== signedAmount) {
        setValidationError("Split lines must add up exactly to the transaction total.");
        return;
      }
      input.subtransactions = parsedLines.map(({ line, amount: lineAmount }) => ({
        id: line.id,
        amount: lineAmount!,
        ...line.transferAccountId
          ? {
              transfer_account_id: line.transferAccountId,
              transfer_transaction_id: line.transferTransactionId,
              payee_id: line.payeeId,
              category_id: line.categoryId || null,
            }
          : {
              ...payeeInput(line.payeeName, line.payeeId, line.originalPayeeName, payees),
              category_id: line.categoryId || null,
            },
        memo: line.memo.trim() || null,
      }));
    } else if (!isTransfer) {
      Object.assign(input, payeeInput(payeeName, transaction.payee_id, transaction.payee_name ?? "", payees), {
        category_id: categoryId || null,
      });
    }

    setValidationError(null);
    await onSave(transaction.id, input);
  };

  return (
    <section className="transaction-editor" aria-labelledby="edit-transaction-heading">
      <div className="section-heading">
        <div>
          <span className="section-title" id="edit-transaction-heading">Edit transaction</span>
          <span className="section-meta">{transaction.account_name ?? "Account"} · {isTransfer ? `Transfer to ${transferTarget}` : isSplit ? "Split transaction" : "Posted transaction"}</span>
        </div>
        <button type="button" className="text-button" onClick={onCancel} disabled={disabled}>Cancel</button>
      </div>
      <form className="transaction-editor-form" onSubmit={(event) => void submit(event)}>
        <div className="field-row transaction-editor-top-row">
          <label className="field">
            <span className="field-label">Date</span>
            <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required />
          </label>
          <label className="field">
            <span className="field-label">Amount</span>
            <input
              type="number"
              inputMode="decimal"
              step="0.001"
              min="0"
              value={amount}
              onChange={(event) => setAmount(event.target.value)}
              required
            />
            <span className="field-note">{direction < 0 ? "Outflow" : "Inflow"}; direction and posting account stay unchanged.</span>
          </label>
        </div>

        {!isTransfer && !isSplit && (
          <>
            <label className="field">
              <span className="field-label">Payee</span>
              <input list="editor-payee-options" value={payeeName} onChange={(event) => setPayeeName(event.target.value)} placeholder="Payee" autoComplete="off" />
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              <CategorySelect value={categoryId} onChange={setCategoryId} groups={orderedGroups} />
            </label>
          </>
        )}

        {isSplit && (
          <fieldset className="transaction-editor-splits">
            <legend>Split lines</legend>
            <p className={splitTotal === (direction * (parentAmount ?? 0)) ? "split-remainder split-remainder-ok" : "split-remainder"}>
              {splitTotal === (direction * (parentAmount ?? 0)) ? "Lines match the total." : "Lines must add up exactly to the total."}
            </p>
            {splitLines.map((line, index) => {
              const lineTransferTarget = accounts.find((account) => account.id === line.transferAccountId)?.name ?? "linked account";
              return (
                <div key={line.id} className="transaction-editor-split-line">
                  <label>
                    <span className="sr-only">Split line {index + 1} amount</span>
                    <input type="number" inputMode="decimal" step="0.001" value={line.amount} onChange={(event) => updateSplit(line.id, { amount: event.target.value })} />
                  </label>
                  {line.transferAccountId ? (
                    <span className="transaction-editor-transfer-line">Transfer to {lineTransferTarget}</span>
                  ) : (
                    <>
                      <label>
                        <span className="sr-only">Split line {index + 1} payee</span>
                        <input value={line.payeeName} onChange={(event) => updateSplit(line.id, { payeeName: event.target.value })} placeholder="Payee" list="editor-payee-options" />
                      </label>
                      <label>
                        <span className="sr-only">Split line {index + 1} category</span>
                        <CategorySelect value={line.categoryId} onChange={(value) => updateSplit(line.id, { categoryId: value })} groups={orderedGroups} />
                      </label>
                    </>
                  )}
                  <label>
                    <span className="sr-only">Split line {index + 1} memo</span>
                    <input value={line.memo} onChange={(event) => updateSplit(line.id, { memo: event.target.value })} placeholder="Line memo" />
                  </label>
                </div>
              );
            })}
          </fieldset>
        )}

        <label className="field">
          <span className="field-label">Memo</span>
          <input value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="Note" />
        </label>
        <div className="transaction-editor-status-row">
          <label className="field">
            <span className="field-label">Flag</span>
            <select value={flagColor} onChange={(event) => setFlagColor(event.target.value)}>
              <option value="">None</option>
              {['red', 'orange', 'yellow', 'green', 'blue', 'purple'].map((colour) => <option key={colour} value={colour}>{colour[0]!.toUpperCase() + colour.slice(1)}</option>)}
            </select>
          </label>
          <label className="transaction-editor-checkbox">
            <input type="checkbox" checked={approved} onChange={(event) => setApproved(event.target.checked)} />
            Approved
          </label>
        </div>
        {validationError && <p className="transaction-editor-error" role="alert">{validationError}</p>}
        <div className="transaction-editor-actions">
          <button type="button" className="text-button" onClick={onCancel} disabled={disabled}>Cancel</button>
          <button type="submit" className="save-button" disabled={disabled}>{saving ? "Saving..." : "Save changes"}</button>
        </div>
        <datalist id="editor-payee-options">
          {payees.filter((payee) => !payee.deleted && !payee.transfer_account_id).map((payee) => <option key={payee.id} value={payee.name} />)}
        </datalist>
      </form>
    </section>
  );
}
