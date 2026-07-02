import { useMemo, useRef, useState } from "react";
import { api } from "../api/client";
import type { Account, Payee, Transaction } from "../api/types";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate, todayIso } from "../lib/dates";
import { decimalToMilli, formatAmount, formatMoney } from "../lib/money";
import { usePlan } from "../state/plan";
import { PayeeCombobox } from "./PayeeCombobox";

const SPLIT_SENTINEL = "__split__";

/** "Transfer : {Account}" in the payee field means a transfer, matching imported YNAB data. */
export function transferTargetAccount(payeeName: string, accounts: Account[], excludeId: string): Account | null {
  const match = payeeName.match(/^Transfer\s*:\s*(.+)$/i);
  if (!match) {
    return null;
  }
  const name = match[1].trim().toLowerCase();
  return accounts.find((account) => !account.closed && account.id !== excludeId && account.name.toLowerCase() === name) ?? null;
}

/** Paired outflow/inflow inputs, YNAB register style: filling one clears the other. */
function useOutflowInflow(initialAmount?: number) {
  const [outflow, setOutflow] = useState(initialAmount !== undefined && initialAmount < 0 ? (Math.abs(initialAmount) / 1000).toFixed(2) : "");
  const [inflow, setInflow] = useState(initialAmount !== undefined && initialAmount > 0 ? (initialAmount / 1000).toFixed(2) : "");

  const amountMilli = (): number | null => {
    if (outflow.trim()) {
      return -Math.abs(decimalToMilli(outflow));
    }
    if (inflow.trim()) {
      return Math.abs(decimalToMilli(inflow));
    }
    return null;
  };

  return {
    outflow,
    inflow,
    setOutflow: (value: string) => {
      setOutflow(value);
      if (value.trim()) {
        setInflow("");
      }
    },
    setInflow: (value: string) => {
      setInflow(value);
      if (value.trim()) {
        setOutflow("");
      }
    },
    amountMilli,
    reset: () => {
      setOutflow("");
      setInflow("");
    },
  };
}

export function CategoryOptions() {
  const { categoryGroups } = usePlan();
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  return (
    <>
      {[...orderedGroups.primary, ...orderedGroups.quiet].map((group) => (
        <optgroup key={group.id} label={group.name}>
          {group.categories.map((category) => (
            <option key={category.id} value={category.id}>
              {category.name}
            </option>
          ))}
        </optgroup>
      ))}
    </>
  );
}

/* ── Splits ─────────────────────────────────────────────────── */

interface SplitLine {
  key: number;
  id?: string;
  category_id: string;
  memo: string;
  outflow: string;
  inflow: string;
}

let splitLineKey = 0;

function emptySplitLine(): SplitLine {
  splitLineKey += 1;
  return { key: splitLineKey, category_id: "", memo: "", outflow: "", inflow: "" };
}

function splitLinesFromTransaction(txn: Transaction): SplitLine[] {
  return (txn.subtransactions ?? []).map((sub) => {
    splitLineKey += 1;
    return {
      key: splitLineKey,
      id: sub.id,
      category_id: sub.category_id ?? "",
      memo: sub.memo ?? "",
      outflow: sub.amount < 0 ? (Math.abs(sub.amount) / 1000).toFixed(2) : "",
      inflow: sub.amount > 0 ? (sub.amount / 1000).toFixed(2) : "",
    };
  });
}

function splitLineAmount(line: SplitLine): number | null {
  if (line.outflow.trim()) {
    return -Math.abs(decimalToMilli(line.outflow));
  }
  if (line.inflow.trim()) {
    return Math.abs(decimalToMilli(line.inflow));
  }
  return null;
}

/** Validated subtransaction inputs, or an error describing what is missing. */
function buildSubtransactions(
  lines: SplitLine[],
  parentAmount: number | null,
): { subtransactions: Array<{ id?: string; amount: number; category_id: string | null; memo: string | null }> } | { error: string } {
  if (lines.length < 2) {
    return { error: "A split needs at least two lines — or pick a single category instead." };
  }
  if (parentAmount === null) {
    return { error: "Enter the transaction amount before saving the split." };
  }
  const amounts = lines.map(splitLineAmount);
  if (amounts.some((amount) => amount === null)) {
    return { error: "Every split line needs an outflow or inflow amount." };
  }
  const total = (amounts as number[]).reduce((sum, amount) => sum + amount, 0);
  if (total !== parentAmount) {
    return {
      error: `Split lines must add up to the transaction amount (${formatMoney(parentAmount - total, { sign: true })} left to assign).`,
    };
  }
  return {
    subtransactions: lines.map((line, index) => ({
      id: line.id,
      amount: amounts[index] as number,
      category_id: line.category_id || null,
      memo: line.memo.trim() || null,
    })),
  };
}

function SplitLinesEditor({
  lines,
  setLines,
  parentAmount,
}: {
  lines: SplitLine[];
  setLines: (lines: SplitLine[]) => void;
  parentAmount: number | null;
}) {
  const patchLine = (key: number, patch: Partial<SplitLine>) => {
    setLines(
      lines.map((line) => {
        if (line.key !== key) {
          return line;
        }
        const next = { ...line, ...patch };
        // Outflow and inflow are exclusive per line, like the main register.
        if (patch.outflow?.trim()) {
          next.inflow = "";
        }
        if (patch.inflow?.trim()) {
          next.outflow = "";
        }
        return next;
      }),
    );
  };

  const assigned = lines.reduce((sum, line) => sum + (splitLineAmount(line) ?? 0), 0);
  const remaining = parentAmount === null ? null : parentAmount - assigned;

  return (
    <div className="split-editor">
      {lines.map((line, index) => (
        <div key={line.key} className="split-line">
          <select
            value={line.category_id}
            onChange={(event) => patchLine(line.key, { category_id: event.target.value })}
            aria-label={`Split ${index + 1} category`}
          >
            <option value="">Uncategorised</option>
            <CategoryOptions />
          </select>
          <input
            value={line.memo}
            onChange={(event) => patchLine(line.key, { memo: event.target.value })}
            placeholder="Memo"
            aria-label={`Split ${index + 1} memo`}
          />
          <input
            type="number"
            step="0.01"
            min="0"
            value={line.outflow}
            onChange={(event) => patchLine(line.key, { outflow: event.target.value })}
            placeholder="Outflow"
            className="amount-cell-input outflow-input"
            aria-label={`Split ${index + 1} outflow`}
          />
          <input
            type="number"
            step="0.01"
            min="0"
            value={line.inflow}
            onChange={(event) => patchLine(line.key, { inflow: event.target.value })}
            placeholder="Inflow"
            className="amount-cell-input inflow-input"
            aria-label={`Split ${index + 1} inflow`}
          />
          <button
            type="button"
            className="text-button"
            onClick={() => setLines(lines.filter((entry) => entry.key !== line.key))}
            disabled={lines.length <= 2}
            title={lines.length <= 2 ? "A split needs at least two lines" : "Remove this line"}
          >
            ×
          </button>
        </div>
      ))}
      <div className="split-footer">
        <button type="button" className="text-button" onClick={() => setLines([...lines, emptySplitLine()])}>
          + Add another split
        </button>
        <span className={remaining === 0 ? "split-remaining split-remaining-ok" : "split-remaining"}>
          {remaining === null
            ? "Enter the transaction amount to balance the split."
            : remaining === 0
              ? "All assigned"
              : `${formatMoney(remaining, { sign: true })} left to assign`}
        </span>
      </div>
    </div>
  );
}

/** Category picker that can flip into split mode, YNAB's "Split (Multiple Categories)". */
function CategoryField({
  categoryId,
  setCategoryId,
  splitMode,
  onEnterSplit,
  onExitSplit,
}: {
  categoryId: string;
  setCategoryId: (id: string) => void;
  splitMode: boolean;
  onEnterSplit: () => void;
  onExitSplit: () => void;
}) {
  return (
    <select
      value={splitMode ? SPLIT_SENTINEL : categoryId}
      onChange={(event) => {
        if (event.target.value === SPLIT_SENTINEL) {
          onEnterSplit();
        } else {
          onExitSplit();
          setCategoryId(event.target.value);
        }
      }}
    >
      <option value="">Uncategorised</option>
      <option value={SPLIT_SENTINEL}>Split (multiple categories)…</option>
      <CategoryOptions />
    </select>
  );
}

/* ── Row chrome ─────────────────────────────────────────────── */

/** YNAB-style cleared circle: click toggles uncleared/cleared; reconciled is locked. */
export function ClearedBadge({
  transaction: txn,
  planId,
  onChanged,
}: {
  transaction: Transaction;
  planId: string;
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState(false);
  if (txn.cleared === "reconciled") {
    return (
      <span className="cleared-badge cleared-reconciled" title="Reconciled (locked)">
        R
      </span>
    );
  }
  const isCleared = txn.cleared === "cleared";
  return (
    <button
      type="button"
      className={isCleared ? "cleared-badge cleared-on" : "cleared-badge"}
      title={isCleared ? "Cleared — click to unclear" : "Uncleared — click to clear"}
      disabled={busy}
      onClick={async (event) => {
        event.stopPropagation();
        setBusy(true);
        try {
          await api.updateTransaction(planId, txn.id, { cleared: isCleared ? "uncleared" : "cleared" });
          onChanged();
        } finally {
          setBusy(false);
        }
      }}
    >
      C
    </button>
  );
}

/** One-click categorisation straight from the register, shown as YNAB's "needs a category" pill. */
export function QuickCategorySelect({
  planId,
  transactionId,
  onChanged,
}: {
  planId: string;
  transactionId: string;
  onChanged: () => void;
}) {
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
      <option value="">{busy ? "Saving…" : "Needs a category"}</option>
      <CategoryOptions />
    </select>
  );
}

/* ── Add row ────────────────────────────────────────────────── */

/**
 * Inline new-transaction row at the top of the register, mirroring YNAB's
 * Add Transaction: outflow/inflow fields, transfers via the payee field,
 * splits, and "Save and add another" for batch entry.
 */
export function AddTransactionRow({
  planId,
  defaultAccountId,
  payees,
  onSaved,
  onClose,
}: {
  planId: string;
  defaultAccountId?: string;
  payees: Payee[];
  onSaved: () => void;
  onClose: () => void;
}) {
  const { accounts } = usePlan();
  const openAccounts = useMemo(() => accounts.filter((account) => !account.closed), [accounts]);

  const [date, setDate] = useState(todayIso());
  const [accountId, setAccountId] = useState(defaultAccountId ?? openAccounts[0]?.id ?? "");
  const [payeeName, setPayeeName] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [memo, setMemo] = useState("");
  const [splitMode, setSplitMode] = useState(false);
  const [splitLines, setSplitLines] = useState<SplitLine[]>([]);
  const amounts = useOutflowInflow();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedNote, setSavedNote] = useState<string | null>(null);
  const payeeRef = useRef<HTMLInputElement>(null);

  const transferTarget = transferTargetAccount(payeeName, accounts, accountId);

  const save = async (addAnother: boolean) => {
    setBusy(true);
    setError(null);
    try {
      const amount = amounts.amountMilli();
      if (amount === null) {
        throw new Error("Enter an outflow or an inflow amount.");
      }
      if (!payeeName.trim() && !transferTarget) {
        throw new Error("Enter a payee, or pick a transfer from the payee list.");
      }
      if (transferTarget) {
        await api.createTransfer(planId, {
          from_account_id: amount < 0 ? accountId : transferTarget.id,
          to_account_id: amount < 0 ? transferTarget.id : accountId,
          amount_milli: Math.abs(amount),
          date,
          memo: memo.trim() || null,
        });
      } else {
        let subtransactions;
        if (splitMode) {
          const built = buildSubtransactions(splitLines, amount);
          if ("error" in built) {
            throw new Error(built.error);
          }
          subtransactions = built.subtransactions;
        }
        await api.createTransaction(planId, {
          account_id: accountId,
          date,
          amount,
          payee_name: payeeName.trim(),
          category_id: splitMode ? null : categoryId || null,
          memo: memo.trim() || null,
          cleared: "uncleared",
          approved: true,
          ...(subtransactions ? { subtransactions } : {}),
        });
      }
      if (addAnother) {
        setSavedNote(`${transferTarget ? "Transfer" : payeeName.trim()} · ${formatAmount(amount)} saved`);
        setPayeeName("");
        setCategoryId("");
        setMemo("");
        setSplitMode(false);
        setSplitLines([]);
        amounts.reset();
        setBusy(false);
        onSaved();
        payeeRef.current?.focus();
      } else {
        onSaved();
        onClose();
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  return (
    <tr className="editor-row add-row">
      <td colSpan={9}>
        <form
          className="txn-editor"
          onSubmit={(event) => {
            event.preventDefault();
            save(false);
          }}
        >
          <div className="txn-editor-grid">
            <label className="field">
              <span className="field-label">Date</span>
              <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required />
            </label>
            <label className="field">
              <span className="field-label">Account</span>
              <select value={accountId} onChange={(event) => setAccountId(event.target.value)}>
                {openAccounts.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              <span className="field-label">Payee</span>
              <PayeeCombobox
                value={payeeName}
                onChange={setPayeeName}
                accounts={accounts}
                currentAccountId={accountId}
                payees={payees}
                placeholder="Payee or transfer"
                autoFocus
                inputRef={payeeRef}
              />
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              {transferTarget ? (
                <input value="Category not needed" disabled />
              ) : (
                <CategoryField
                  categoryId={categoryId}
                  setCategoryId={setCategoryId}
                  splitMode={splitMode}
                  onEnterSplit={() => {
                    setSplitMode(true);
                    setSplitLines((lines) => (lines.length >= 2 ? lines : [emptySplitLine(), emptySplitLine()]));
                  }}
                  onExitSplit={() => setSplitMode(false)}
                />
              )}
            </label>
            <label className="field">
              <span className="field-label">Memo</span>
              <input value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="Note" />
            </label>
            <label className="field">
              <span className="field-label">Outflow</span>
              <input
                type="number"
                step="0.01"
                min="0"
                value={amounts.outflow}
                onChange={(event) => amounts.setOutflow(event.target.value)}
                placeholder="0.00"
                className="amount-cell-input outflow-input"
              />
            </label>
            <label className="field">
              <span className="field-label">Inflow</span>
              <input
                type="number"
                step="0.01"
                min="0"
                value={amounts.inflow}
                onChange={(event) => amounts.setInflow(event.target.value)}
                placeholder="0.00"
                className="amount-cell-input inflow-input"
              />
            </label>
          </div>

          {splitMode && !transferTarget && (
            <SplitLinesEditor lines={splitLines} setLines={setSplitLines} parentAmount={amounts.amountMilli()} />
          )}

          {transferTarget && (
            <p className="field-note">
              Saves as a linked transfer between {accountNameById(accounts, accountId)} and {transferTarget.name}. Use
              outflow to send money out of {accountNameById(accounts, accountId)}, inflow to bring it in.
            </p>
          )}
          {error && (
            <div className="status-panel status-panel-error compact-panel">
              <p className="status-title">Could not save.</p>
              <p className="status-detail">{error}</p>
            </div>
          )}
          {savedNote && !error && <p className="field-note saved-note">{savedNote}</p>}

          <div className="txn-editor-actions">
            <button type="submit" disabled={busy}>
              {busy ? "Saving…" : "Save"}
            </button>
            <button type="button" disabled={busy} onClick={() => save(true)}>
              Save and add another
            </button>
            <button type="button" className="text-button" onClick={onClose} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      </td>
    </tr>
  );
}

function accountNameById(accounts: Account[], accountId: string): string {
  return accounts.find((account) => account.id === accountId)?.name ?? "this account";
}

/* ── Edit row ───────────────────────────────────────────────── */

export function TransactionEditorRow({
  transaction: txn,
  planId,
  payees,
  onDone,
  onCancel,
}: {
  transaction: Transaction;
  planId: string;
  payees: Payee[];
  onDone: () => void;
  onCancel: () => void;
}) {
  const { accounts } = usePlan();

  const isTransfer = Boolean(txn.transfer_transaction_id || txn.transfer_account_id);

  const [date, setDate] = useState(txn.date);
  const [accountId, setAccountId] = useState(txn.account_id);
  const [payeeName, setPayeeName] = useState(txn.payee_name ?? "");
  const [categoryId, setCategoryId] = useState(txn.category_id ?? "");
  const [memo, setMemo] = useState(txn.memo ?? "");
  const [cleared, setCleared] = useState(txn.cleared);
  const [splitMode, setSplitMode] = useState(Boolean(txn.subtransactions?.length));
  const [splitLines, setSplitLines] = useState<SplitLine[]>(() => splitLinesFromTransaction(txn));
  const amounts = useOutflowInflow(txn.amount);
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
        const amount = amounts.amountMilli();
        if (amount === null) {
          throw new Error("Enter an outflow or an inflow amount.");
        }
        patch.amount = amount;
        if (splitMode) {
          const built = buildSubtransactions(splitLines, amount);
          if ("error" in built) {
            throw new Error(built.error);
          }
          patch.subtransactions = built.subtransactions;
          patch.category_id = null;
        } else {
          patch.category_id = categoryId || null;
          if (txn.subtransactions?.length) {
            patch.subtransactions = [];
          }
        }
        if (accountId !== txn.account_id) {
          patch.account_id = accountId;
        }
      }
      await api.updateTransaction(planId, txn.id, patch);
      onDone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  };

  const remove = async () => {
    const message = isTransfer
      ? "Delete this transfer? Both sides of the pair will be removed."
      : "Delete this transaction? This cannot be undone from the web app.";
    if (!window.confirm(message)) {
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
      <td colSpan={9}>
        <form className="txn-editor" onSubmit={save}>
          <div className="txn-editor-grid">
            <label className="field">
              <span className="field-label">Date</span>
              <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required />
            </label>
            <label className="field">
              <span className="field-label">Account</span>
              <select value={accountId} onChange={(event) => setAccountId(event.target.value)} disabled={isTransfer}>
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
              <PayeeCombobox
                value={payeeName}
                onChange={setPayeeName}
                accounts={accounts}
                currentAccountId={accountId}
                payees={payees}
                disabled={isTransfer}
                placeholder={isTransfer ? "Transfer" : "Payee"}
              />
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              {isTransfer ? (
                <input value="Category not needed" disabled />
              ) : (
                <CategoryField
                  categoryId={categoryId}
                  setCategoryId={setCategoryId}
                  splitMode={splitMode}
                  onEnterSplit={() => {
                    setSplitMode(true);
                    setSplitLines((lines) => (lines.length >= 2 ? lines : [emptySplitLine(), emptySplitLine()]));
                  }}
                  onExitSplit={() => setSplitMode(false)}
                />
              )}
            </label>
            <label className="field">
              <span className="field-label">Memo</span>
              <input value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="Note" />
            </label>
            <label className="field">
              <span className="field-label">Outflow</span>
              <input
                type="number"
                step="0.01"
                min="0"
                value={amounts.outflow}
                onChange={(event) => amounts.setOutflow(event.target.value)}
                disabled={isTransfer}
                className="amount-cell-input outflow-input"
              />
            </label>
            <label className="field">
              <span className="field-label">Inflow</span>
              <input
                type="number"
                step="0.01"
                min="0"
                value={amounts.inflow}
                onChange={(event) => amounts.setInflow(event.target.value)}
                disabled={isTransfer}
                className="amount-cell-input inflow-input"
              />
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

          {splitMode && !isTransfer && (
            <SplitLinesEditor lines={splitLines} setLines={setSplitLines} parentAmount={amounts.amountMilli()} />
          )}

          {isTransfer && (
            <p className="field-note">
              This entry is one side of a transfer; the account, payee, category, and amount stay linked to the other
              side.
            </p>
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
            <button type="button" className="text-button danger" onClick={remove} disabled={busy}>
              Delete
            </button>
          </div>
        </form>
      </td>
    </tr>
  );
}

/* ── Register row ───────────────────────────────────────────── */

export function RegisterRow({
  transaction: txn,
  planId,
  showAccount,
  selected,
  onToggleSelect,
  onEdit,
  onChanged,
}: {
  transaction: Transaction;
  planId: string;
  showAccount: boolean;
  selected: boolean;
  onToggleSelect: () => void;
  onEdit: () => void;
  onChanged: () => void;
}) {
  const canQuickCategorise = txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length;
  return (
    <tr className={selected ? "register-row register-row-selected" : "register-row"} onClick={onEdit}>
      <td className="select-cell" onClick={(event) => event.stopPropagation()}>
        <input
          type="checkbox"
          checked={selected}
          onChange={onToggleSelect}
          aria-label={`Select transaction: ${txn.payee_name ?? txn.date}`}
        />
      </td>
      <td className="nowrap">{formatDate(txn.date)}</td>
      {showAccount && <td className="muted">{txn.account_name}</td>}
      <td>
        {!txn.approved && <span className="new-dot" title="New — not yet approved" />}
        {txn.payee_name ?? (txn.transfer_account_id ? "Transfer" : "-")}
      </td>
      <td className="muted">
        {txn.subtransactions?.length ? (
          `Split · ${txn.subtransactions.length} lines`
        ) : txn.transfer_account_id ? (
          "Category not needed"
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
      <td className="cleared-cell">
        <ClearedBadge transaction={txn} planId={planId} onChanged={onChanged} />
      </td>
    </tr>
  );
}
