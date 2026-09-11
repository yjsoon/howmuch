import { startTransition, useDeferredValue, useEffect, useMemo, useRef, useState, Fragment, type ReactNode } from "react";
import { NavLink, useSearchParams } from "react-router-dom";
import { ApiError, api, BulkApprovalError, useApi } from "../api/client";
import type {
  Account,
  AccountReconciliationPreview,
  AccountReconciliationResult,
  CategoryGroup,
  Payee,
  ReconciliationMismatchDetail,
  ScheduledTransaction,
  Transaction,
} from "../api/types";
import { colourNamesByAccount, ledgerFlagNames, namedFlagLabel } from "../lib/reward-flag-names";
import { FilterRail } from "../components/FilterRail";
import { FlagTag } from "../components/FlagTag";
import { RegisterComposeRow } from "../components/RegisterComposeRow";
import { RegisterEditableRow, type RowEditSurface } from "../components/RegisterEditableRow";
import { splitCategoryGroups, UNCATEGORISED_CATEGORY_ID } from "../lib/categories";
import { formatDate, todayIso, trailingMonthsRange } from "../lib/dates";
import { stableHash } from "../lib/hash";
import { formatAmount, formatMoney, parseMilliunits } from "../lib/money";
import {
  approveAllLabel,
  approveSelectedLabel,
  approvedToast,
  beginApproval,
  eligibleApprovalIds,
  emptyApprovalSession,
  failApproval,
  finishApproval,
  interruptedToast,
  planApproval,
  rowLooksApproved,
} from "../lib/register-approval";
import {
  closedCompose,
  composePayload,
  reduceCompose,
  type RegisterComposeState,
} from "../lib/register-compose";
import {
  focusForRowError,
  idleRowEdit,
  planRowCommit,
  reduceRowEdit,
  rowId,
  sessionRowGone,
  type RegisterRowEditAction,
  type RegisterRowEditSession,
} from "../lib/register-row-edit";
import { dateInRegisterWindow, isUpcomingRegisterDate, registerFetchUntilDate } from "../lib/register-current";
import { fillRegisterHorizon, REGISTER_PAGE_SIZE } from "../lib/register-horizon";
import {
  fieldsFromSchedule,
  matchesRegisterQuery,
  mergeSearchRows,
  parseRegisterQuery,
  searchStatusCopy,
  transactionMatchesQuery,
} from "../lib/register-search";
import { applyClearedOverlays, applyRegisterPatches, deletedIdsForRemoval, reconcileClearedOverlays, retainInFlightPatches, unlinkSplitMirrorParent } from "../lib/register-rows";
import {
  emptySelection,
  headerState,
  reduceSelection,
  selectedIds,
  type RegisterSelectionIntent,
} from "../lib/register-selection";
import { activeSchedulesForScope, scheduledAmount, scheduleRecurrence, transferScheduleLabel } from "../lib/schedules";
import { useFilters } from "../state/filters";
import { usePlan } from "../state/plan";

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
  const { filters, setFilters } = useFilters({ defaultRange: () => trailingMonthsRange(2) });
  const { accounts, categoryGroups, planId, reload } = usePlan();
  const payees = useApi(planId, () => api.payees(planId));
  const rewardsSnapshot = useApi(`${planId}:reward-flag-names`, () => api.rewardsTrackerSnapshot(planId));
  const colourNamesByAccountId = useMemo(
    () => colourNamesByAccount(rewardsSnapshot.data?.cards),
    [rewardsSnapshot.data],
  );
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
  const today = todayIso();
  const fetchUntilDate = registerFetchUntilDate(filters.to, today);
  const pageQuery = useMemo(
    () => ({ since_date: filters.from, until_date: fetchUntilDate, limit: REGISTER_PAGE_SIZE }),
    [fetchUntilDate, filters.from],
  );
  const [page, setPage] = useState({
    transactions: [] as Transaction[],
    hasMore: false,
    nextOffset: null as number | null,
    loading: true,
    filling: true,
    loadingMore: false,
    loaded: false,
    error: null as string | null,
  });
  const [searchPage, setSearchPage] = useState({
    query: "",
    transactions: [] as Transaction[],
    hasMore: false,
    nextOffset: null as number | null,
    loading: false,
    loadingMore: false,
    error: null as string | null,
  });
  const registerQuery = useMemo(() => parseRegisterQuery(deferredSearch), [deferredSearch]);
  const searchVersionRef = useRef(0);
  const [pendingDeletion, setPendingDeletion] = useState<Transaction | null>(null);
  const [reconcileDraft, setReconcileDraft] = useState<ReconcileDraft | null>(null);
  const [reconciliationPreviewGeneration, setReconciliationPreviewGeneration] = useState(0);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [mutationSuccess, setMutationSuccess] = useState<string | null>(null);
  const [mutatingId, setMutatingId] = useState<string | null>(null);
  const [unapprovedOnly, setUnapprovedOnly] = useState(false);
  const [selection, setSelection] = useState(() => emptySelection(listKey));
  const [replacements, setReplacements] = useState<ReadonlyMap<string, Transaction>>(() => new Map());
  const [clearedOverlays, setClearedOverlays] = useState<ReadonlyMap<string, Transaction["cleared"]>>(() => new Map());
  const [rowEdit, setRowEdit] = useState<RegisterRowEditSession>(idleRowEdit);
  const rowEditRef = useRef(rowEdit);
  const replaceRowEdit = (next: RegisterRowEditSession) => {
    rowEditRef.current = next;
    setRowEdit(next);
  };
  const [deletedIds, setDeletedIds] = useState<ReadonlySet<string>>(() => new Set());
  const [approvalSession, setApprovalSession] = useState(emptyApprovalSession);
  const approvalSessionRef = useRef(approvalSession);
  const [compose, setCompose] = useState<RegisterComposeState>(closedCompose);
  const [composeFocus, setComposeFocus] = useState(0);
  const mutationLockRef = useRef(false);
  const clearedInFlightRef = useRef(new Set<string>());
  const [writeLocked, setWriteLocked] = useState(false);
  const selectedAccountId = filters.accountIds.length === 1 ? filters.accountIds[0]! : null;
  const composeScope = selectedAccountId ?? (filters.accountIds.join(",") || "all");
  useEffect(() => {
    setCompose(closedCompose());
  }, [composeScope]);
  const schedules = useApi<ScheduledTransaction[]>(
    `${planId}:scheduled-transactions`,
    () => api.scheduledTransactions(planId),
  );
  const approvalQueue = useApi(
    JSON.stringify({ planId, selectedAccountId, from: filters.from, to: filters.to, refreshGeneration, approvalQueue: true }),
    async () => {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const transactions = new Map<string, Transaction>();
        let expectedKnowledge: number | null = null;
        let offset = 0;
        let changed = false;
        for (;;) {
          const query = { since_date: filters.from, until_date: fetchUntilDate, type: "unapproved" as const, limit: 250, offset };
          const result = selectedAccountId
            ? await api.accountTransactions(planId, selectedAccountId, query)
            : await api.transactions(planId, query);
          expectedKnowledge ??= result.server_knowledge;
          if (result.server_knowledge !== expectedKnowledge) {
            changed = true;
            break;
          }
          for (const transaction of result.transactions) transactions.set(transaction.id, transaction);
          if (!result.has_more || result.next_offset === null) return [...transactions.values()];
          offset = result.next_offset;
        }
        if (!changed) return [...transactions.values()];
      }
      throw new Error("Transactions changed while the approval queue was loading. Try again.");
    },
  );
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

  const refreshFirstPage = () => {
    requestVersionRef.current += 1;
    setPage({ transactions: [], hasMore: false, nextOffset: null, loading: true, filling: true, loadingMore: false, loaded: false, error: null });
    setRefreshGeneration((generation) => generation + 1);
  };

  useEffect(() => {
    let cancelled = false;
    const requestVersion = ++requestVersionRef.current;
    setPage({ transactions: [], hasMore: false, nextOffset: null, loading: true, filling: true, loadingMore: false, loaded: false, error: null });
    fillRegisterHorizon({
      today: todayIso(),
      accountId: selectedAccountId,
      fetchPage: fetchTransactionPage,
      isCurrent: () => !cancelled && requestVersion === requestVersionRef.current,
      onProgress: (update) => {
        setPage({
          transactions: update.transactions,
          hasMore: update.hasMore,
          nextOffset: update.nextOffset,
          loading: false,
          filling: !update.done,
          loadingMore: false,
          loaded: true,
          error: null,
        });
      },
    })
      .then((filled) => {
        if (!filled) {
          return;
        }
        setPage({
          transactions: filled.transactions,
          hasMore: filled.hasMore,
          nextOffset: filled.nextOffset,
          loading: false,
          filling: false,
          loadingMore: false,
          loaded: true,
          error: null,
        });
      })
      .catch((error: Error) => {
        if (!cancelled && requestVersion === requestVersionRef.current) {
          setPage({ transactions: [], hasMore: false, nextOffset: null, loading: false, filling: false, loadingMore: false, loaded: false, error: error.message });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [listKey, refreshGeneration]);

  useEffect(() => {
    setReplacements((current) => retainInFlightPatches(current, clearedInFlightRef.current));
    setDeletedIds(new Set());
    replaceRowEdit(idleRowEdit());
    const empty = emptyApprovalSession();
    approvalSessionRef.current = empty;
    setApprovalSession(empty);
  }, [listKey, refreshGeneration]);

  useEffect(() => {
    setClearedOverlays((current) => {
      if (current.size === 0) return current;
      const next = reconcileClearedOverlays(
        current,
        [page.transactions, approvalQueue.data ?? []],
        clearedInFlightRef.current,
      );
      if (next.size === current.size) {
        let same = true;
        for (const [id, cleared] of next) {
          if (current.get(id) !== cleared) {
            same = false;
            break;
          }
        }
        if (same) return current;
      }
      return next;
    });
  }, [approvalQueue.data, page.transactions, searchPage.transactions]);

  const searchQueryParams = (offset: number) => ({
    q: registerQuery?.raw,
    since_date: filters.from,
    until_date: fetchUntilDate,
    limit: REGISTER_PAGE_SIZE,
    offset,
  });

  useEffect(() => {
    const q = registerQuery?.raw;
    if (!q || unapprovedOnly) {
      searchVersionRef.current += 1;
      setSearchPage({
        query: "",
        transactions: [],
        hasMore: false,
        nextOffset: null,
        loading: false,
        loadingMore: false,
        error: null,
      });
      return;
    }
    let cancelled = false;
    const version = ++searchVersionRef.current;
    setSearchPage({
      query: q,
      transactions: [],
      hasMore: false,
      nextOffset: null,
      loading: true,
      loadingMore: false,
      error: null,
    });
    const params = searchQueryParams(0);
    const request = selectedAccountId
      ? api.accountTransactions(planId, selectedAccountId, params)
      : api.transactions(planId, params);
    request
      .then((result) => {
        if (cancelled || version !== searchVersionRef.current) {
          return;
        }
        setSearchPage({
          query: q,
          transactions: result.transactions,
          hasMore: result.has_more,
          nextOffset: result.next_offset,
          loading: false,
          loadingMore: false,
          error: null,
        });
      })
      .catch((error: Error) => {
        if (cancelled || version !== searchVersionRef.current) {
          return;
        }
        setSearchPage({
          query: q,
          transactions: [],
          hasMore: false,
          nextOffset: null,
          loading: false,
          loadingMore: false,
          error: error.message,
        });
      });
    return () => {
      cancelled = true;
    };
  }, [fetchUntilDate, filters.from, planId, registerQuery?.raw, selectedAccountId, unapprovedOnly, refreshGeneration]);

  const loadOlder = async () => {
    if (registerQuery && !unapprovedOnly) {
      if (searchPage.loadingMore || !searchPage.hasMore || searchPage.nextOffset === null) {
        return;
      }
      const requestedOffset = searchPage.nextOffset;
      const version = searchVersionRef.current;
      setSearchPage((current) => ({ ...current, loadingMore: true, error: null }));
      try {
        const params = searchQueryParams(requestedOffset);
        const older = selectedAccountId
          ? await api.accountTransactions(planId, selectedAccountId, params)
          : await api.transactions(planId, params);
        setSearchPage((current) => version !== searchVersionRef.current || current.nextOffset !== requestedOffset
          ? current
          : {
            ...current,
            transactions: [
              ...current.transactions,
              ...older.transactions.filter((transaction) => !current.transactions.some((loaded) => loaded.id === transaction.id)),
            ],
            hasMore: older.has_more,
            nextOffset: older.next_offset,
            loadingMore: false,
            error: null,
          });
      } catch (error) {
        setSearchPage((current) => version !== searchVersionRef.current || current.nextOffset !== requestedOffset
          ? current
          : { ...current, loadingMore: false, error: (error as Error).message });
      }
      return;
    }
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

  const toggleCleared = async (transaction: Transaction) => {
    if (mutationLockRef.current || (transaction.cleared !== "uncleared" && transaction.cleared !== "cleared")) return;
    if (clearedInFlightRef.current.has(transaction.id)) return;
    const cleared = transaction.cleared === "cleared" ? "uncleared" : "cleared";
    const overlay = { ...transaction, cleared };
    clearedInFlightRef.current.add(transaction.id);
    setClearedOverlays((current) => new Map(current).set(transaction.id, cleared));
    setReplacements((current) => new Map(current).set(transaction.id, overlay));
    setMutatingId(transaction.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      const updated = await api.updateTransactionCleared(planId, transaction.id, transaction.cleared, cleared);
      setReplacements((current) => new Map(current).set(updated.id, updated));
      reload();
      setReconciliationPreviewGeneration((generation) => generation + 1);
    } catch (cause) {
      setClearedOverlays((current) => {
        const next = new Map(current);
        next.delete(transaction.id);
        return next;
      });
      setReplacements((current) => new Map(current).set(transaction.id, transaction));
      setMutationError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      clearedInFlightRef.current.delete(transaction.id);
      setMutatingId((current) => (current === transaction.id ? null : current));
    }
  };

  const deleteTransaction = async (transaction: Transaction) => {
    if (mutationLockRef.current) return;
    setMutatingId(transaction.id);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      const deleted = await api.deleteTransaction(planId, transaction.id, transaction.approved ? undefined : false);
      const removed = new Set([
        ...deletedIdsForRemoval(transaction),
        ...(deleted.id ? deletedIdsForRemoval(deleted) : []),
      ]);
      const mirror = {
        id: deleted.id || transaction.id,
        parent_transaction_id: deleted.parent_transaction_id ?? transaction.parent_transaction_id,
        transfer_transaction_id: deleted.transfer_transaction_id ?? transaction.transfer_transaction_id,
      };
      setDeletedIds((current) => new Set([...current, ...removed]));
      setReplacements((current) => {
        const byId = new Map<string, Transaction>();
        for (const row of page.transactions) {
          byId.set(row.id, row);
        }
        for (const row of approvalQueue.data ?? []) {
          byId.set(row.id, row);
        }
        for (const [id, row] of current) {
          byId.set(id, row);
        }
        const parent = unlinkSplitMirrorParent([...byId.values()], mirror);
        return parent ? new Map(current).set(parent.id, parent) : current;
      });
      setPendingDeletion((current) => (current && removed.has(current.id) ? null : current));
      const session = rowEditRef.current;
      if (session.status !== "idle" && removed.has(rowId(session.row))) {
        replaceRowEdit(idleRowEdit());
      }
      reload();
      setReconciliationPreviewGeneration((generation) => generation + 1);
    } catch (cause) {
      setMutationError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setMutatingId((current) => (current === transaction.id ? null : current));
    }
  };

  const openCompose = () => {
    if (!canCompose) {
      return;
    }
    if (rowEditRef.current.status === "editing") {
      replaceRowEdit(idleRowEdit());
    }
    setCompose((current) => reduceCompose(current, {
      type: "open",
      accountId: lockedComposeAccount?.id ?? "",
    }));
    setComposeFocus((nonce) => nonce + 1);
    setMutationError(null);
    setMutationSuccess(null);
  };

  const dispatchRowEdit = (action: RegisterRowEditAction) => {
    replaceRowEdit(reduceRowEdit(rowEditRef.current, action));
  };

  const commitRowEdit = async (options: { approve: boolean }) => {
    const session = rowEditRef.current;
    if (session.status !== "editing" || mutationLockRef.current) {
      return;
    }
    const plan = planRowCommit(session.row, session.draft, payees.data ?? [], options);
    if (plan.kind === "unchanged") {
      dispatchRowEdit({ type: "cancel" });
      return;
    }
    if (plan.kind === "invalid") {
      dispatchRowEdit({
        type: "invalid",
        message: plan.message,
        focus: focusForRowError(plan.message, session.row, session.draft, payees.data ?? []),
      });
      return;
    }
    mutationLockRef.current = true;
    setWriteLocked(true);
    setMutatingId(rowId(session.row));
    setMutationError(null);
    setMutationSuccess(null);
    dispatchRowEdit({ type: "committing" });
    try {
      const updated = await api.updateTransaction(planId, plan.transactionId, plan.input);
      setReplacements((current) => new Map(current).set(updated.id, updated));
      const prior = session.row.kind === "posted" ? session.row.transaction : session.row.parent;
      const priorMirrors = [
        prior.transfer_transaction_id,
        ...(prior.subtransactions ?? []).map((line) => line.transfer_transaction_id),
      ].filter((id): id is string => Boolean(id));
      const nextMirrors = new Set([
        updated.transfer_transaction_id,
        ...(updated.subtransactions ?? []).map((line) => line.transfer_transaction_id),
      ].filter((id): id is string => Boolean(id)));
      const dropped = priorMirrors.filter((id) => !nextMirrors.has(id));
      if (dropped.length > 0) {
        setDeletedIds((current) => new Set([...current, ...dropped]));
      }
      reload();
      refreshFirstPage();
      setReconciliationPreviewGeneration((generation) => generation + 1);
      const savedName = (updated.payee_name ?? session.draft.payeeName).trim() || "Entry";
      setMutationSuccess(
        dateInRegisterWindow(updated.date, filters.from, filters.to, today)
          ? `${savedName} saved.`
          : `${savedName} saved. It is outside this date range.`,
      );
      dispatchRowEdit({ type: "committed" });
    } catch (cause) {
      dispatchRowEdit({
        type: "failed",
        message: cause instanceof Error ? cause.message : String(cause),
      });
    } finally {
      mutationLockRef.current = false;
      setWriteLocked(false);
      setMutatingId(null);
    }
  };

  const saveCompose = async (keepOpen: boolean) => {
    if (compose.status !== "open" || mutationLockRef.current) {
      return;
    }
    const result = composePayload(compose.draft, payees.data ?? []);
    if (!result.ok) {
      setCompose((current) => reduceCompose(current, { type: "failed", error: result.error }));
      return;
    }
    mutationLockRef.current = true;
    setWriteLocked(true);
    setMutatingId("compose");
    setMutationError(null);
    setMutationSuccess(null);
    setCompose((current) => reduceCompose(current, { type: "saving" }));
    try {
      const transaction = await api.quickEntry(result.input);
      reload();
      setPage((current) => {
        if (!current.loaded || current.transactions.some((row) => row.id === transaction.id)) {
          return current;
        }
        if (!registerAccountIds.has(transaction.account_id) || !dateInRegisterWindow(transaction.date, filters.from, filters.to, today)) {
          return current;
        }
        return { ...current, transactions: [transaction, ...current.transactions] };
      });
      setReconciliationPreviewGeneration((generation) => generation + 1);
      const savedName = transaction.payee_name ?? "Entry";
      setMutationSuccess(
        dateInRegisterWindow(transaction.date, filters.from, filters.to, today)
          ? `${savedName} saved.`
          : `${savedName} saved. It is outside this date range.`,
      );
      setCompose((current) => reduceCompose(current, { type: "saved", keepOpen }));
      if (keepOpen) {
        setComposeFocus((nonce) => nonce + 1);
      }
    } catch (cause) {
      setCompose((current) => reduceCompose(current, {
        type: "failed",
        error: cause instanceof Error ? cause.message : String(cause),
      }));
    } finally {
      mutationLockRef.current = false;
      setWriteLocked(false);
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
    setWriteLocked(true);
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
      setWriteLocked(false);
      setMutatingId(null);
    }
  };

  const wantsUncategorised = filters.categoryIds.includes(UNCATEGORISED_CATEGORY_ID);
  const categoryIds = useMemo(
    () => new Set(filters.categoryIds.filter((categoryId) => categoryId !== UNCATEGORISED_CATEGORY_ID)),
    [filters.categoryIds],
  );

  const patchedQueue = useMemo(
    () =>
      applyClearedOverlays(
        applyRegisterPatches(approvalQueue.data ?? [], replacements, deletedIds).map((txn) =>
          !txn.approved && rowLooksApproved(txn, approvalSession) ? { ...txn, approved: true } : txn,
        ),
        clearedOverlays,
      ),
    [approvalQueue.data, approvalSession, clearedOverlays, deletedIds, replacements],
  );
  const patchedPage = useMemo(
    () =>
      applyClearedOverlays(
        applyRegisterPatches(page.transactions, replacements, deletedIds).map((txn) =>
          !txn.approved && rowLooksApproved(txn, approvalSession) ? { ...txn, approved: true } : txn,
        ),
        clearedOverlays,
      ),
    [approvalSession, clearedOverlays, deletedIds, page.transactions, replacements],
  );
  const patchedSearch = useMemo(
    () =>
      applyClearedOverlays(
        applyRegisterPatches(searchPage.transactions, replacements, deletedIds).map((txn) =>
          !txn.approved && rowLooksApproved(txn, approvalSession) ? { ...txn, approved: true } : txn,
        ),
        clearedOverlays,
      ),
    [approvalSession, clearedOverlays, deletedIds, replacements, searchPage.transactions],
  );
  const inScope = useMemo(
    () =>
      (unapprovedOnly ? patchedQueue : patchedPage)
        .filter((txn) => !txn.deleted)
        .filter((txn) => registerAccountIds.has(txn.account_id))
        .filter((txn) => unapprovedOnly || dateInRegisterWindow(txn.date, filters.from, filters.to, today)),
    [filters.from, filters.to, patchedPage, patchedQueue, registerAccountIds, today, unapprovedOnly],
  );

  const uncategorisedCount = useMemo(() => inScope.filter(hasUncategorisedLine).length, [inScope]);
  const unapprovedCount = useMemo(
    () =>
      patchedQueue.filter(
        (transaction) => !transaction.deleted && registerAccountIds.has(transaction.account_id) && !transaction.approved,
      ).length,
    [patchedQueue, registerAccountIds],
  );

  const scopedRows = useMemo(() => {
    const outflowOnly = flow === "outflow" || wantsUncategorised;
    return inScope
      .filter((txn) => !unapprovedOnly || !txn.approved)
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
  }, [categoryIds, filters.categoryIds.length, flow, inScope, unapprovedOnly, wantsUncategorised]);

  const editingRowId = rowEdit.status === "idle" ? null : rowId(rowEdit.row);
  const applyRowFilters = (rows: Transaction[]) => {
    const outflowOnly = flow === "outflow" || wantsUncategorised;
    return rows
      .filter((txn) => !txn.deleted)
      .filter((txn) => registerAccountIds.has(txn.account_id))
      .filter((txn) => unapprovedOnly || dateInRegisterWindow(txn.date, filters.from, filters.to, today))
      .filter((txn) => !unapprovedOnly || !txn.approved)
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
      });
  };
  const matchedRows = useMemo(() => {
    const localMatches = scopedRows.filter((txn) => {
      if (editingRowId && txn.id === editingRowId) {
        return true;
      }
      return transactionMatchesQuery(registerQuery, txn);
    });
    if (!registerQuery) {
      return scopedRows;
    }
    if (unapprovedOnly) {
      return localMatches;
    }
    return mergeSearchRows(localMatches, applyRowFilters(patchedSearch));
  }, [
    categoryIds,
    editingRowId,
    filters.categoryIds.length,
    filters.from,
    filters.to,
    flow,
    patchedSearch,
    registerAccountIds,
    registerQuery,
    scopedRows,
    today,
    unapprovedOnly,
    wantsUncategorised,
  ]);
  const rows = useMemo(
    () => matchedRows.filter((txn) => !isUpcomingRegisterDate(txn.date, today)),
    [matchedRows, today],
  );
  const postedFutureRows = useMemo(
    () => matchedRows.filter((txn) => isUpcomingRegisterDate(txn.date, today)),
    [matchedRows, today],
  );
  const visibleSchedules = useMemo(() => {
    if (unapprovedOnly) {
      return [];
    }
    const query = registerQuery;
    return activeSchedulesForScope(schedules.data ?? [], registerAccountIds).filter((schedule) => {
      if (filters.categoryIds.length) {
        const matchesCategory =
          (typeof schedule.category_id === "string" && categoryIds.has(schedule.category_id))
          || schedule.subtransactions?.some((line) => typeof line.category_id === "string" && categoryIds.has(line.category_id));
        const uncategorised = !schedule.category_id && !schedule.transfer_account_id
          && !(schedule.subtransactions?.some((line) => line.category_id || line.transfer_account_id));
        if (!matchesCategory && !(wantsUncategorised && uncategorised)) {
          return false;
        }
      }
      if (!query) {
        return true;
      }
      const accountName = accounts.find((account) => account.id === schedule.account_id)?.name;
      const payeeName = schedule.payee_name ?? (schedule.payee_id ? payees.data?.find((payee) => payee.id === schedule.payee_id)?.name : undefined);
      return matchesRegisterQuery(query, fieldsFromSchedule(schedule, { accountName, payeeName }));
    });
  }, [accounts, categoryIds, filters.categoryIds.length, payees.data, registerAccountIds, registerQuery, schedules.data, unapprovedOnly, wantsUncategorised]);
  const scheduledDisclosureCount = postedFutureRows.length + visibleSchedules.length;
  const showScheduledDisclosure = scheduledDisclosureCount > 0 || Boolean(schedules.error);

  useEffect(() => {
    const present = new Set(scopedRows.map((txn) => txn.id));
    if (sessionRowGone(rowEdit, present)) {
      replaceRowEdit(idleRowEdit());
    }
  }, [rowEdit, scopedRows]);

  const eligibleIds = useMemo(
    () => eligibleApprovalIds(matchedRows, approvalSession),
    [approvalSession, matchedRows],
  );
  const selectionRows = useMemo(() => eligibleIds.map((id) => ({ id })), [eligibleIds]);
  const dispatchSelection = (intent: RegisterSelectionIntent) => {
    setSelection((current) => reduceSelection(current, selectionRows, intent, listKey));
  };
  const selectedApprovalIds = useMemo(
    () => selectedIds(selection, selectionRows, listKey),
    [listKey, selection, selectionRows],
  );
  const selectedApprovalIdSet = useMemo(() => new Set(selectedApprovalIds), [selectedApprovalIds]);
  const selectionHeader = useMemo(
    () => headerState(selection, selectionRows, listKey),
    [listKey, selection, selectionRows],
  );

  const approveMany = async (transactionIds: readonly string[]) => {
    const plan = planApproval(transactionIds, matchedRows, approvalSessionRef.current);
    if (mutationLockRef.current || !plan) return;
    const plannedIds = plan.flat();
    const started = beginApproval(approvalSessionRef.current, plannedIds);
    if (!started) return;
    approvalSessionRef.current = started;
    setApprovalSession(started);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      const result = await api.approveTransactions(planId, plannedIds);
      const finished = finishApproval(approvalSessionRef.current, plannedIds);
      approvalSessionRef.current = finished;
      setApprovalSession(finished);
      dispatchSelection({ kind: "none" });
      setMutationSuccess(approvedToast(result.approvedCount));
    } catch (cause) {
      const approvedCount = cause instanceof BulkApprovalError ? cause.approvedCount : 0;
      const failed = failApproval(approvalSessionRef.current, plannedIds, approvedCount);
      approvalSessionRef.current = failed;
      setApprovalSession(failed);
      if (cause instanceof BulkApprovalError && cause.approvedCount > 0) {
        setMutationError(interruptedToast(
          cause.approvedCount,
          Math.max(0, plannedIds.length - cause.approvedCount),
        ));
      } else {
        setMutationError(cause instanceof Error ? cause.message : String(cause));
      }
    }
  };

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
      ? "No transactions yet."
      : deferredSearch.trim()
        ? "No transactions match this search."
        : "No transactions match these filters.";
  const mutationBusy = writeLocked || Boolean(mutatingId);
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const rowSurface: RowEditSurface = {
    session: rowEdit,
    context: { writeLocked, mutatingId },
    payees: payees.data ?? [],
    accounts,
    groups: orderedGroups,
    begin: (action) => {
      setCompose((current) => (
        current.status === "open" && !current.saving
          ? reduceCompose(current, { type: "close" })
          : current
      ));
      dispatchRowEdit(action);
    },
    dispatch: dispatchRowEdit,
    commit: (options) => {
      void commitRowEdit(options);
    },
    cancel: () => dispatchRowEdit({ type: "cancel" }),
  };
  const lockedComposeAccount = selectedAccount && !selectedAccount.closed ? selectedAccount : null;
  const composeAccounts = useMemo(
    () => visibleAccounts.filter((account) => !account.closed),
    [visibleAccounts],
  );
  const canCompose = Boolean(lockedComposeAccount || composeAccounts.length);
  const reconciliationBusy = mutationBusy;
  const reviewedStatementBalance = reconcileDraft ? parseMilliunits(reconcileDraft.statementBalance) : null;
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
      <FilterRail filters={filters} setFilters={setFilters} busy={page.loading || page.filling || page.loadingMore} />
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
          <button
            type="button"
            className="register-add-link"
            onClick={openCompose}
            disabled={!canCompose || mutationBusy}
            title={!canCompose && selectedAccount?.closed ? "This account is closed" : undefined}
          >
            + Add transaction
          </button>
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
          {(unapprovedCount > 0 || unapprovedOnly) && (
            <button
              type="button"
              className={unapprovedOnly ? "approval-pill approval-pill-active" : "approval-pill"}
              onClick={() => setUnapprovedOnly((current) => !current)}
            >
              {unapprovedOnly ? "Showing new transactions · clear" : `${unapprovedCount} new to approve`}
            </button>
          )}
          {unapprovedOnly && eligibleIds.length > 0 && (
            <button
              type="button"
              className="approval-pill"
              onClick={() => void approveMany(eligibleIds)}
              disabled={writeLocked || eligibleIds.some((id) => approvalSession.pending.has(id))}
            >
              {eligibleIds.some((id) => approvalSession.pending.has(id))
                ? "Approving…"
                : approveAllLabel(eligibleIds.length)}
            </button>
          )}
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
              placeholder="Search payee, memo, category, account, or amount…"
              value={search}
              onChange={(event) => startTransition(() => setSearch(event.target.value))}
              aria-label="Search transactions"
            />
            <span className="search-meta">
              {registerQuery
                ? searchStatusCopy({
                    shown: rows.length,
                    scheduled: visibleSchedules.length,
                    hasMore: searchPage.hasMore,
                    loading: searchPage.loading,
                    error: searchPage.error,
                  })
                : `Showing ${rows.length} of ${scopedRows.length} loaded filtered entries`}
            </span>
            {filters.accountIds.length > 1 && (registerQuery ? searchPage.hasMore : page.hasMore) && (
              <span className="search-meta">Load older entries to extend this multi-account result.</span>
            )}
          </div>
        </div>
      </div>

      {selectedApprovalIds.length > 0 && (
        <div className="register-bulk-bar" role="group" aria-label="Selected transaction actions">
          <span className="register-bulk-count">{selectedApprovalIds.length} selected</span>
          <button
            type="button"
            className="approval-pill"
            onClick={() => void approveMany(selectedApprovalIds)}
            disabled={writeLocked || selectedApprovalIds.some((id) => approvalSession.pending.has(id))}
          >
            {selectedApprovalIds.some((id) => approvalSession.pending.has(id))
              ? "Approving…"
              : approveSelectedLabel(selectedApprovalIds.length)}
          </button>
          <button
            type="button"
            className="text-button"
            onClick={() => dispatchSelection({ kind: "none" })}
            disabled={mutationBusy}
          >
            Clear
          </button>
        </div>
      )}
      {page.error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">Could not load {page.loaded ? "older " : ""}transactions.</p>
          <p className="status-detail">{page.error}</p>
        </div>
      )}
      {approvalQueue.error && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not load transactions awaiting approval.</p>
          <p className="status-detail">{approvalQueue.error}</p>
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
                <p className="status-title">The statement balance does not match the reconciled total.</p>
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
            <h2 id="delete-transaction-heading">{pendingDeletion.approved ? "Delete transaction?" : "Reject new transaction?"}</h2>
            <p id="delete-transaction-detail">
              {pendingDeletion.payee_name ?? (pendingDeletion.transfer_account_id ? "This transfer" : "This transaction")} will be deleted.
              {pendingDeletion.parent_transaction_id
                ? " The split line on the other account stays and loses this transfer link."
                : pendingDeletion.transfer_transaction_id
                  ? " Its linked transfer entry will also be removed."
                  : ""}
            </p>
          </div>
          <div className="transaction-delete-confirm-actions">
            <button type="button" className="text-button" onClick={() => setPendingDeletion(null)} disabled={writeLocked || mutatingId === pendingDeletion.id}>Cancel</button>
            <button type="button" className="transaction-delete-button" onClick={() => void deleteTransaction(pendingDeletion)} disabled={writeLocked || mutatingId === pendingDeletion.id}>
              {mutatingId === pendingDeletion.id ? "Removing..." : pendingDeletion.approved ? "Delete transaction" : "Reject transaction"}
            </button>
          </div>
        </section>
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
          {rows.length > 0 || showScheduledDisclosure || compose.status === "open" ? (
            <div className="table-wrap table-wrap-wide">
              <table className="ledger-table register-table">
                <thead>
                  <tr>
                    <th className="register-select-heading">
                      <input
                        type="checkbox"
                        ref={(node) => {
                          if (node) node.indeterminate = selectionHeader === "some";
                        }}
                        checked={selectionHeader === "all"}
                        onChange={() => dispatchSelection({
                          kind: selectionHeader === "all" ? "none" : "all",
                        })}
                        disabled={mutationBusy || eligibleIds.length === 0}
                        aria-label="Select all visible unapproved transactions"
                      />
                    </th>
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
                  {compose.status === "open" && (
                    <RegisterComposeRow
                      state={compose}
                      accounts={composeAccounts}
                      lockedAccount={lockedComposeAccount}
                      payees={payees.data ?? []}
                      categoryGroups={categoryGroups}
                      disabled={mutationBusy && mutatingId !== "compose"}
                      focusNonce={composeFocus}
                      flagNames={ledgerFlagNames(colourNamesByAccountId.get(compose.draft.accountId) ?? {})}
                      onChange={setCompose}
                      onCancel={() => {
                        setCompose(closedCompose());
                        setMutationError(null);
                      }}
                      onSave={(keepOpen) => void saveCompose(keepOpen)}
                    />
                  )}
                  {showScheduledDisclosure && (
                    <RegisterScheduledDisclosure
                      key={selectedAccountId ?? "all"}
                      schedules={visibleSchedules}
                      posted={postedFutureRows}
                      loading={schedules.loading}
                      error={schedules.error}
                      accounts={accounts}
                      categoryGroups={categoryGroups}
                      payees={payees.data ?? []}
                      renderPosted={(txn) => [
                        <RegisterEditableRow
                          key={txn.id}
                          row={{ kind: "posted", transaction: txn }}
                          surface={rowSurface}
                          leading={!txn.approved && !txn.deleted ? (
                            <input
                              type="checkbox"
                              checked={selectedApprovalIdSet.has(txn.id)}
                              onClick={(event) => {
                                const index = eligibleIds.indexOf(txn.id);
                                if (index >= 0) {
                                  dispatchSelection({
                                    kind: event.shiftKey ? "extend" : "toggle",
                                    index,
                                  });
                                }
                              }}
                              onChange={() => {}}
                              disabled={mutationBusy}
                              aria-label={`Select ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                            />
                          ) : null}
                          account={txn.account_name}
                          actions={(
                            <>
                              {!txn.approved && (
                                <button
                                  type="button"
                                  className="register-row-action register-row-action-approve"
                                  onClick={() => void approveMany([txn.id])}
                                  disabled={writeLocked || approvalSession.pending.has(txn.id)}
                                  aria-label={`Approve ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                                >
                                  {approvalSession.pending.has(txn.id) ? "Approving…" : "Approve"}
                                </button>
                              )}
                              <button
                                type="button"
                                className="register-row-action register-row-action-danger"
                                onClick={() => {
                                  setPendingDeletion(txn);
                                  setMutationError(null);
                                }}
                                disabled={writeLocked || mutatingId === txn.id}
                                aria-label={`${txn.approved ? "Delete" : "Reject"} ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                              >
                                {txn.approved ? "Delete" : "Reject"}
                              </button>
                            </>
                          )}
                          status={(
                            <ClearedStatus
                              transaction={txn}
                              busy={writeLocked || mutatingId === txn.id}
                              onToggle={() => void toggleCleared(txn)}
                            />
                          )}
                          payeeExtra={<FlagTag colour={txn.flag_color} name={namedFlagLabel(colourNamesByAccountId.get(txn.account_id), txn.flag_color, txn.flag_name)} />}
                          flagNames={ledgerFlagNames(colourNamesByAccountId.get(txn.account_id) ?? {})}
                        />,
                        ...(txn.subtransactions ?? []).map((sub) => (
                          <RegisterEditableRow
                            key={sub.id}
                            row={{ kind: "split-line", parent: txn, lineId: sub.id }}
                            surface={rowSurface}
                            leading={null}
                            account={null}
                            actions={null}
                            status={null}
                          />
                        )),
                      ]}
                    />
                  )}
                  {rows.flatMap((txn) => [
                    <RegisterEditableRow
                      key={txn.id}
                      row={{ kind: "posted", transaction: txn }}
                      surface={rowSurface}
                      leading={!txn.approved && !txn.deleted ? (
                        <input
                          type="checkbox"
                          checked={selectedApprovalIdSet.has(txn.id)}
                          onClick={(event) => {
                            const index = eligibleIds.indexOf(txn.id);
                            if (index >= 0) {
                              dispatchSelection({
                                kind: event.shiftKey ? "extend" : "toggle",
                                index,
                              });
                            }
                          }}
                          onChange={() => {}}
                          disabled={mutationBusy}
                          aria-label={`Select ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                        />
                      ) : null}
                      account={txn.account_name}
                      actions={(
                        <>
                          {!txn.approved && (
                            <button
                              type="button"
                              className="register-row-action register-row-action-approve"
                              onClick={() => void approveMany([txn.id])}
                              disabled={writeLocked || approvalSession.pending.has(txn.id)}
                              aria-label={`Approve ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                            >
                              {approvalSession.pending.has(txn.id) ? "Approving…" : "Approve"}
                            </button>
                          )}
                          <button
                            type="button"
                            className="register-row-action register-row-action-danger"
                            onClick={() => {
                              setPendingDeletion(txn);
                              setMutationError(null);
                            }}
                            disabled={writeLocked || mutatingId === txn.id}
                            aria-label={`${txn.approved ? "Delete" : "Reject"} ${txn.payee_name ?? (txn.transfer_account_id ? "transfer" : "transaction")} on ${formatDate(txn.date)}`}
                          >
                            {txn.approved ? "Delete" : "Reject"}
                          </button>
                        </>
                      )}
                      status={(
                        <ClearedStatus
                          transaction={txn}
                          busy={writeLocked || mutatingId === txn.id}
                          onToggle={() => void toggleCleared(txn)}
                        />
                      )}
                      payeeExtra={<FlagTag colour={txn.flag_color} name={namedFlagLabel(colourNamesByAccountId.get(txn.account_id), txn.flag_color, txn.flag_name)} />}
                      flagNames={ledgerFlagNames(colourNamesByAccountId.get(txn.account_id) ?? {})}
                    />,
                    ...(txn.subtransactions ?? []).map((sub) => (
                      <RegisterEditableRow
                        key={sub.id}
                        row={{ kind: "split-line", parent: txn, lineId: sub.id }}
                        surface={rowSurface}
                        leading={null}
                        account={null}
                        actions={null}
                        status={null}
                      />
                    )),
                  ])}
                </tbody>
              </table>
              {rows.length === 0 && !page.filling && compose.status !== "open" && !showScheduledDisclosure && (
                <div className="register-empty-state">
                  <p className="status-title">{emptyMessage}</p>
                  <p className="status-detail">Try widening the date range, clearing filters, or shortening the search term.</p>
                </div>
              )}
            </div>
          ) : page.filling ? null : (
            <div className="status-panel">
              <p className="status-title">{emptyMessage}</p>
              <p className="status-detail">Try widening the date range, clearing filters, or shortening the search term.</p>
            </div>
          )}
          {((registerQuery && !unapprovedOnly) ? searchPage.hasMore : page.hasMore) && !page.filling && !unapprovedOnly && (
            <div className="register-load-more">
              <button
                type="button"
                className="register-load-more-button"
                onClick={loadOlder}
                disabled={registerQuery ? searchPage.loadingMore : page.loadingMore}
              >
                {registerQuery
                  ? (searchPage.loadingMore ? "Loading older matches…" : "Load older matches")
                  : (page.loadingMore ? "Loading older transactions…" : "Load older transactions")}
              </button>
            </div>
          )}
        </section>
      )}
    </>
  );
}

function RegisterScheduledDisclosure({
  schedules,
  posted,
  loading,
  error,
  accounts,
  categoryGroups,
  payees,
  renderPosted,
}: {
  schedules: ScheduledTransaction[];
  posted: Transaction[];
  loading: boolean;
  error: string | null;
  accounts: Account[];
  categoryGroups: CategoryGroup[];
  payees: Payee[];
  renderPosted: (transaction: Transaction) => ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  const accountNames = new Map(accounts.map((account) => [account.id, account.name]));
  const categoryNames = new Map(categoryGroups.flatMap((group) => group.categories ?? []).map((category) => [category.id, category.name]));
  const payeeNames = new Map(payees.map((payee) => [payee.id, payee.name]));
  const count = posted.length + schedules.length;
  const summary = error && count === 0
    ? "Unavailable"
    : String(count);

  const scheduleRows = (schedule: ScheduledTransaction) => {
    const amount = scheduledAmount(schedule);
    const transfer = schedule.transfer_account_id ? transferScheduleLabel(schedule.transfer_account_id, accountNames) : null;
    const payee = schedule.payee_name
      ?? (schedule.payee_id ? payeeNames.get(schedule.payee_id) : null)
      ?? transfer
      ?? "No payee";
    const category = schedule.subtransactions?.length
      ? `Split · ${schedule.subtransactions.length} lines`
      : transfer ?? schedule.category_name ?? (schedule.category_id ? categoryNames.get(schedule.category_id) : null) ?? "Uncategorised";
    const accountName = (typeof schedule.account_id === "string" ? accountNames.get(schedule.account_id) : undefined) ?? "Account";
    return [
      <tr key={schedule.id} className="register-scheduled-row">
        <td />
        <td className="nowrap">{schedule.date_next ? formatDate(schedule.date_next) : "No next date"}</td>
        <td>{accountName}</td>
        <td>{payee}</td>
        <td className="muted">Scheduled · {scheduleRecurrence(schedule.frequency)} · {category}</td>
        <td className="muted memo-cell" title={schedule.memo ?? ""}>{schedule.memo ?? "-"}</td>
        <td className="num amount-negative">{amount < 0 ? formatAmount(amount) : ""}</td>
        <td className="num amount-positive">{amount > 0 ? formatAmount(amount) : ""}</td>
        <td className="register-actions"><NavLink className="register-row-action" to="/scheduled">Manage</NavLink></td>
        <td />
      </tr>,
      ...(schedule.subtransactions ?? []).map((line) => {
        const lineTransfer = line.transfer_account_id ? transferScheduleLabel(line.transfer_account_id, accountNames) : null;
        return <tr key={line.id} className="split-line-row register-scheduled-split-row">
          <td />
          <td />
          <td />
          <td className="muted split-line-cell">↳ {line.payee_name ?? (line.payee_id ? payeeNames.get(line.payee_id) : null) ?? lineTransfer ?? "-"}</td>
          <td className="muted">{lineTransfer ?? line.category_name ?? (line.category_id ? categoryNames.get(line.category_id) : null) ?? "Uncategorised"}</td>
          <td className="muted memo-cell" title={line.memo ?? ""}>{line.memo ?? "-"}</td>
          <td className="num amount-negative">{line.amount < 0 ? formatAmount(line.amount) : ""}</td>
          <td className="num amount-positive">{line.amount > 0 ? formatAmount(line.amount) : ""}</td>
          <td />
          <td />
        </tr>;
      }),
    ];
  };

  const expandedRows = [
    ...posted.map((transaction) => ({
      date: transaction.date,
      kind: 0 as const,
      id: transaction.id,
      node: renderPosted(transaction),
    })),
    ...schedules.map((schedule) => ({
      date: schedule.date_next ?? schedule.date_first ?? "9999-12-31",
      kind: 1 as const,
      id: schedule.id,
      node: scheduleRows(schedule),
    })),
  ].sort((left, right) => right.date.localeCompare(left.date) || left.kind - right.kind || left.id.localeCompare(right.id));

  if (error && count === 0) {
    return (
      <tr className="register-scheduled-message">
        <td colSpan={10}>
          <span role="alert">Could not load scheduled transactions: {error}</span>
          {" · "}
          <NavLink to="/scheduled">Manage schedules</NavLink>
        </td>
      </tr>
    );
  }

  return (
    <>
      <tr className="register-scheduled-disclosure-row">
        <td colSpan={10}>
          <button
            type="button"
            className="register-scheduled-disclosure"
            aria-expanded={expanded}
            onClick={() => setExpanded((current) => !current)}
          >
            <svg className="register-scheduled-icon" viewBox="0 0 20 20" aria-hidden="true">
              <path d="M4 6.5h12M6.5 3.5v4M13.5 3.5v4M4 5h12v12H4z" />
            </svg>
            <span>Scheduled</span>
            <span className="register-scheduled-count">{summary}</span>
            <span className="register-scheduled-chevron" aria-hidden="true">›</span>
          </button>
        </td>
      </tr>
      {expanded && loading && count === 0 && (
        <tr className="register-scheduled-message"><td colSpan={10}><span role="status">Loading scheduled transactions…</span></td></tr>
      )}
      {expanded && expandedRows.map((entry) => (
        <Fragment key={`${entry.kind}-${entry.id}`}>{entry.node}</Fragment>
      ))}
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
