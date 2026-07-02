import { useMemo, useRef, useState } from "react";
import { api } from "../api/client";
import type { Account, Payee, Transaction } from "../api/types";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate, todayIso } from "../lib/dates";
import { decimalToMilli, formatAmount } from "../lib/money";
import { usePlan } from "../state/plan";

/** "Transfer : {Account}" in the payee field means a transfer, matching imported YNAB data. */
export function transferTargetAccount(payeeName: string, accounts: Account[], excludeId: string): Account | null {
  const match = payeeName.match(/^Transfer\s*:\s*(.+)$/i);
  if (!match) {
    return null;
  }
  const name = match[1].trim().toLowerCase();
  return accounts.find((account) => !account.closed && account.id !== excludeId && account.name.toLowerCase() === name) ?? null;
}

function PayeeDatalist({ id, payees, accounts, currentAccountId }: { id: string; payees: Payee[]; accounts: Account[]; currentAccountId: string }) {
  return (
    <datalist id={id}>
      {accounts
        .filter((account) => !account.closed && account.id !== currentAccountId)
        .map((account) => (
          <option key={account.id} value={`Transfer : ${account.name}`} />
        ))}
      {payees
        .filter((payee) => !payee.deleted && !/^Transfer\s*:/i.test(payee.name))
        .map((payee) => (
          <option key={payee.id} value={payee.name} />
        ))}
    </datalist>
  );
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

function CategoryOptions() {
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

/**
 * Inline new-transaction row at the top of the register, mirroring YNAB's
 * Add Transaction: outflow/inflow fields, transfers via the payee field,
 * and "Save and add another" for batch entry.
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
        throw new Error("Enter a payee, or “Transfer : {account}” for a transfer.");
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
        await api.createTransaction(planId, {
          account_id: accountId,
          date,
          amount,
          payee_name: payeeName.trim(),
          category_id: categoryId || null,
          memo: memo.trim() || null,
          cleared: "uncleared",
          approved: true,
        });
      }
      if (addAnother) {
        setSavedNote(`${transferTarget ? "Transfer" : payeeName.trim()} · ${formatAmount(amount)} saved`);
        setPayeeName("");
        setCategoryId("");
        setMemo("");
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
      <td colSpan={8}>
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
              <input
                value={payeeName}
                onChange={(event) => setPayeeName(event.target.value)}
                list="add-payees"
                placeholder="Payee or Transfer : Account"
                ref={payeeRef}
                autoFocus
              />
              <PayeeDatalist id="add-payees" payees={payees} accounts={accounts} currentAccountId={accountId} />
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              {transferTarget ? (
                <input value="Category not needed" disabled />
              ) : (
                <select value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
                  <option value="">Uncategorised</option>
                  <CategoryOptions />
                </select>
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
  const isSplit = Boolean(txn.subtransactions?.length);
  const amountLocked = isTransfer || isSplit;

  const [date, setDate] = useState(txn.date);
  const [accountId, setAccountId] = useState(txn.account_id);
  const [payeeName, setPayeeName] = useState(txn.payee_name ?? "");
  const [categoryId, setCategoryId] = useState(txn.category_id ?? "");
  const [memo, setMemo] = useState(txn.memo ?? "");
  const [cleared, setCleared] = useState(txn.cleared);
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
      }
      if (!amountLocked) {
        const amount = amounts.amountMilli();
        if (amount === null) {
          throw new Error("Enter an outflow or an inflow amount.");
        }
        patch.amount = amount;
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
      <td colSpan={8}>
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
              <input
                value={payeeName}
                onChange={(event) => setPayeeName(event.target.value)}
                list="editor-payees"
                disabled={isTransfer}
                placeholder={isTransfer ? "Transfer" : "Payee"}
              />
              <PayeeDatalist id="editor-payees" payees={payees} accounts={accounts} currentAccountId={accountId} />
            </label>
            <label className="field">
              <span className="field-label">Category</span>
              {isSplit ? (
                <input value={`Split · ${txn.subtransactions?.length} lines`} disabled />
              ) : isTransfer ? (
                <input value="Category not needed" disabled />
              ) : (
                <select value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
                  <option value="">Uncategorised</option>
                  <CategoryOptions />
                </select>
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
                disabled={amountLocked}
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
                disabled={amountLocked}
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
            <button type="button" className="text-button danger" onClick={remove} disabled={busy}>
              Delete
            </button>
          </div>
        </form>
      </td>
    </tr>
  );
}

export function RegisterRow({
  transaction: txn,
  planId,
  showAccount,
  onEdit,
  onChanged,
}: {
  transaction: Transaction;
  planId: string;
  showAccount: boolean;
  onEdit: () => void;
  onChanged: () => void;
}) {
  const canQuickCategorise = txn.category_id === null && !txn.transfer_account_id && !txn.subtransactions?.length;
  return (
    <tr className="register-row" onClick={onEdit}>
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
