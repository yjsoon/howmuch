import { useEffect, useRef, type ReactElement, type ReactNode } from "react";
import type { Account, Payee, Subtransaction, Transaction } from "../api/types";
import type { splitCategoryGroups } from "../lib/categories";
import { formatDate } from "../lib/dates";
import { formatAmount } from "../lib/money";
import { canonicalPayeeName, findTransferPayee, formatComposeAmount } from "../lib/register-compose";
import {
  payeeListEntries,
  postingAccountId,
  rowApproved,
  rowFieldWritable,
  rowGestureHandlers,
  sameRow,
  type RegisterRowEditAction,
  type RegisterRowEditSession,
  type RegisterRowFocus,
  type RegisterRowRef,
  type RowEditContext,
} from "../lib/register-row-edit";
import { CategorySelect } from "./CategorySelect";
import { FlagPicker } from "./FlagTag";

export type RowEditSurface = {
  readonly session: RegisterRowEditSession;
  readonly context: RowEditContext;
  readonly payees: readonly Payee[];
  readonly accounts: readonly Account[];
  readonly groups: ReturnType<typeof splitCategoryGroups>;
  begin(action: Extract<RegisterRowEditAction, { type: "begin" }>): void;
  dispatch(action: RegisterRowEditAction): void;
  commit(options: { approve: boolean }): void;
  cancel(): void;
};

export function RegisterEditableRow(props: {
  row: RegisterRowRef;
  surface: RowEditSurface;
  leading: ReactNode;
  account: ReactNode;
  actions: ReactNode;
  status: ReactNode;
  payeeExtra?: ReactNode;
}): ReactElement | null {
  const { row, surface, leading, account, actions, status, payeeExtra } = props;
  const line = row.kind === "split-line"
    ? row.parent.subtransactions?.find((sub) => sub.id === row.lineId)
    : undefined;
  const active = surface.session.status !== "idle" && sameRow(surface.session.row, row);
  const committing = surface.session.status === "committing" && active;
  const draft = surface.session.status === "idle" ? null : surface.session.draft;
  const error = surface.session.status === "editing" && sameRow(surface.session.row, row)
    ? surface.session.error
    : null;
  const focus = surface.session.status === "editing" && sameRow(surface.session.row, row)
    ? surface.session.focus
    : null;
  const rowRef = useRef<HTMLTableRowElement>(null);
  const approved = rowApproved(row);
  const split = row.kind === "split-line";

  useEffect(() => {
    if (!active || !focus) {
      return;
    }
    const marked = rowRef.current?.querySelector(`[data-row-focus="${focus}"]`);
    const control = marked instanceof HTMLInputElement || marked instanceof HTMLSelectElement
      ? marked
      : marked?.querySelector("input, select");
    if (control instanceof HTMLElement) {
      control.focus();
    }
  }, [active, focus]);

  if (row.kind === "split-line" && !line) {
    return null;
  }

  if (!active || !draft) {
    const className = [
      split ? "split-line-row" : null,
      !split && !approved ? "register-row-unapproved" : null,
    ].filter(Boolean).join(" ") || undefined;
    return (
      <tr className={className}>
        <td className="register-select">{split ? null : leading}</td>
        {split ? <td /> : (
          <IdleCell row={row} focus="date" surface={surface} className="nowrap">
            {formatDate(row.transaction.date)}
          </IdleCell>
        )}
        <td className="muted">{split ? null : account}</td>
        <IdleCell
          row={row}
          focus="payee"
          surface={surface}
          className={split ? "muted split-line-cell" : undefined}
        >
          {idlePayee(row, line)}
          {payeeExtra}
        </IdleCell>
        <IdleCell row={row} focus="category" surface={surface} className="muted">
          {idleCategory(row, line)}
        </IdleCell>
        <IdleCell
          row={row}
          focus="memo"
          surface={surface}
          className="muted memo-cell"
          title={idleMemoTitle(row, line)}
        >
          {idleMemo(row, line)}
        </IdleCell>
        <IdleCell row={row} focus="outflow" surface={surface} className="num amount-negative">
          {idleOutflow(row, line)}
        </IdleCell>
        <IdleCell row={row} focus="inflow" surface={surface} className="num amount-positive">
          {idleInflow(row, line)}
        </IdleCell>
        <td className="register-actions">{split ? null : actions}</td>
        <td className="register-status">{split ? null : status}</td>
      </tr>
    );
  }

  const busy = committing;
  const rowClass = [split ? "split-line-row" : null, "register-compose-row"].filter(Boolean).join(" ");
  const fieldId = rowDomId(row);

  return (
    <>
      <tr
        ref={rowRef}
        className={rowClass}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            if (busy) {
              return;
            }
            event.preventDefault();
            surface.cancel();
          }
          if (event.key === "Enter" && (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement)) {
            event.preventDefault();
            if (!busy) {
              surface.commit({ approve: !approved });
            }
          }
        }}
      >
        <td className="register-select">{split ? null : leading}</td>
        {split ? <td /> : (
          <td>
            {rowFieldWritable(row, "date", draft, surface.payees) ? (
              <RowInput
                id={`${fieldId}-date`}
                focus="date"
                label="Date"
                type="date"
                value={draft.date}
                disabled={busy}
                onChange={(date) => surface.dispatch({ type: "patch", draft: { date } })}
              />
            ) : (
              formatDate(displayTransaction(row).date)
            )}
          </td>
        )}
        <td className="muted">{split ? null : account}</td>
        <td className={split ? "muted split-line-cell" : undefined}>
          {rowFieldWritable(row, "payee", draft, surface.payees) ? (
            <PayeeInput
              id={`${fieldId}-payee`}
              listId={`${fieldId}-payees`}
              value={draft.payeeName}
              disabled={busy}
              payees={surface.payees}
              accounts={surface.accounts}
              postingAccountId={postingAccountId(row)}
              onChange={(payeeName) => surface.dispatch({ type: "patch", draft: { payeeName } })}
            />
          ) : (
            idlePayee(row, line)
          )}
        </td>
        <td className="muted">
          {findTransferPayee(surface.payees, draft.payeeName) ? (
            <span className="register-compose-transfer">Transfer</span>
          ) : rowFieldWritable(row, "category", draft, surface.payees) ? (
            <span data-row-focus="category">
              <CategorySelect
                aria-label="Category"
                value={draft.categoryId}
                onChange={(categoryId) => surface.dispatch({ type: "patch", draft: { categoryId } })}
                groups={surface.groups}
                disabled={busy}
              />
            </span>
          ) : (
            idleCategory(row, line)
          )}
        </td>
        <td>
          {rowFieldWritable(row, "memo", draft, surface.payees) ? (
            <RowInput
              id={`${fieldId}-memo`}
              focus="memo"
              label="Memo"
              type="text"
              value={draft.memo}
              disabled={busy}
              placeholder="Memo"
              onChange={(memo) => surface.dispatch({ type: "patch", draft: { memo } })}
            />
          ) : (
            idleMemo(row, line)
          )}
        </td>
        <td className="num">
          {rowFieldWritable(row, "outflow", draft, surface.payees) ? (
            <AmountInput
              id={`${fieldId}-outflow`}
              focus="outflow"
              label="Outflow"
              value={draft.outflow}
              disabled={busy}
              onChange={(value) => surface.dispatch({ type: "set-outflow", value })}
            />
          ) : (
            idleOutflow(row, line)
          )}
        </td>
        <td className="num">
          {rowFieldWritable(row, "inflow", draft, surface.payees) ? (
            <AmountInput
              id={`${fieldId}-inflow`}
              focus="inflow"
              label="Inflow"
              value={draft.inflow}
              disabled={busy}
              onChange={(value) => surface.dispatch({ type: "set-inflow", value })}
            />
          ) : (
            idleInflow(row, line)
          )}
        </td>
        <td className="register-actions">{split ? null : actions}</td>
        <td className="register-status">{split ? null : status}</td>
      </tr>
      <tr className="register-compose-actions-row">
        <td colSpan={10}>
          <div className="register-compose-actions">
            {split ? null : (
              <>
                <span className="field-label" id={`${fieldId}-flag-label`}>Flag</span>
                <FlagPicker
                  labelledBy={`${fieldId}-flag-label`}
                  value={draft.flagColor}
                  onChange={(flagColor) => surface.dispatch({ type: "patch", draft: { flagColor } })}
                  disabled={busy}
                />
              </>
            )}
            <button type="button" className="register-compose-cancel" onClick={surface.cancel} disabled={busy}>
              Cancel
            </button>
            <button
              type="button"
              className="register-compose-save"
              onClick={() => surface.commit({ approve: !approved })}
              disabled={busy}
            >
              {busy ? (approved ? "Saving…" : "Approving…") : approved ? "Save" : "Approve"}
            </button>
          </div>
        </td>
      </tr>
      {error ? (
        <tr className="register-compose-error-row">
          <td colSpan={10}>
            <p className="register-compose-error" role="alert">{error}</p>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function IdleCell({
  row,
  focus,
  surface,
  className,
  title,
  children,
}: {
  row: RegisterRowRef;
  focus: RegisterRowFocus;
  surface: RowEditSurface;
  className?: string;
  title?: string;
  children: ReactNode;
}): ReactElement {
  const gesture = rowGestureHandlers(row, focus, surface.context, surface.begin);
  return (
    <td
      className={className}
      title={title}
      onMouseDown={gesture.onMouseDown}
      onDoubleClick={gesture.onDoubleClick}
    >
      {children}
    </td>
  );
}

function RowInput({
  id,
  focus,
  label,
  type,
  value,
  disabled,
  placeholder,
  onChange,
}: {
  id: string;
  focus: RegisterRowFocus;
  label: string;
  type: "date" | "text";
  value: string;
  disabled: boolean;
  placeholder?: string;
  onChange: (value: string) => void;
}): ReactElement {
  return (
    <>
      <label className="sr-only" htmlFor={id}>{label}</label>
      <input
        id={id}
        data-row-focus={focus}
        type={type}
        name={focus}
        value={value}
        placeholder={placeholder}
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
      />
    </>
  );
}

function PayeeInput({
  id,
  listId,
  value,
  disabled,
  payees,
  accounts,
  postingAccountId: accountId,
  onChange,
}: {
  id: string;
  listId: string;
  value: string;
  disabled: boolean;
  payees: readonly Payee[];
  accounts: readonly Account[];
  postingAccountId: string;
  onChange: (value: string) => void;
}): ReactElement {
  return (
    <>
      <label className="sr-only" htmlFor={id}>Payee</label>
      <input
        id={id}
        data-row-focus="payee"
        type="text"
        name="payee"
        list={listId}
        value={value}
        autoComplete="off"
        placeholder="Payee"
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
        onBlur={() => {
          const snapped = canonicalPayeeName(payees, value);
          if (snapped !== value) {
            onChange(snapped);
          }
        }}
      />
      <datalist id={listId}>
        {payeeListEntries(payees, accounts, accountId).map((entry) => (
          <option key={entry.id} value={entry.value}>
            {entry.label}
          </option>
        ))}
      </datalist>
    </>
  );
}

function AmountInput({
  id,
  focus,
  label,
  value,
  disabled,
  onChange,
}: {
  id: string;
  focus: "outflow" | "inflow";
  label: string;
  value: string;
  disabled: boolean;
  onChange: (value: string) => void;
}): ReactElement {
  return (
    <>
      <label className="sr-only" htmlFor={id}>{label}</label>
      <input
        id={id}
        data-row-focus={focus}
        type="text"
        inputMode="decimal"
        name={focus}
        value={value}
        placeholder="0.00"
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
        onBlur={() => {
          const next = formatComposeAmount(value);
          if (next !== value) {
            onChange(next);
          }
        }}
      />
    </>
  );
}

function displayTransaction(row: RegisterRowRef): Transaction {
  return row.kind === "posted" ? row.transaction : row.parent;
}

function idlePayee(row: RegisterRowRef, line: Subtransaction | undefined): string {
  if (row.kind === "split-line") {
    return `↳ ${line?.payee_name ?? row.parent.payee_name ?? "-"}`;
  }
  return row.transaction.payee_name ?? (row.transaction.transfer_account_id ? "Transfer" : "-");
}

function idleCategory(row: RegisterRowRef, line: Subtransaction | undefined): string {
  if (row.kind === "split-line") {
    return line?.transfer_account_id ? "Transfer" : (line?.category_name ?? "Uncategorised");
  }
  const txn = row.transaction;
  if (txn.subtransactions?.length) {
    return `Split · ${txn.subtransactions.length} lines`;
  }
  return txn.transfer_account_id ? "Transfer" : (txn.category_name ?? "Uncategorised");
}

function idleMemo(row: RegisterRowRef, line: Subtransaction | undefined): string {
  if (row.kind === "split-line") {
    return line?.memo ?? "-";
  }
  return row.transaction.memo ?? "-";
}

function idleMemoTitle(row: RegisterRowRef, line: Subtransaction | undefined): string {
  if (row.kind === "split-line") {
    return line?.memo ?? "";
  }
  return row.transaction.memo ?? "";
}

function idleOutflow(row: RegisterRowRef, line: Subtransaction | undefined): string {
  const amount = row.kind === "split-line" ? line?.amount ?? 0 : row.transaction.amount;
  return amount < 0 ? formatAmount(amount) : "";
}

function idleInflow(row: RegisterRowRef, line: Subtransaction | undefined): string {
  const amount = row.kind === "split-line" ? line?.amount ?? 0 : row.transaction.amount;
  return amount > 0 ? formatAmount(amount) : "";
}

function rowDomId(row: RegisterRowRef): string {
  return row.kind === "posted"
    ? `register-row-${row.transaction.id}`
    : `register-row-${row.parent.id}-${row.lineId}`;
}
