import { useEffect, useMemo, useRef } from "react";
import type { Account, CategoryGroup, Payee } from "../api/types";
import { CategorySelect } from "./CategorySelect";
import { FlagPicker } from "./FlagTag";
import { splitCategoryGroups } from "../lib/categories";
import {
  canonicalPayeeName,
  findTransferPayee,
  formatComposeAmount,
  reduceCompose,
  type RegisterComposeState,
} from "../lib/register-compose";
import { payeeListEntries } from "../lib/register-row-edit";

export function RegisterComposeRow({
  state,
  accounts,
  lockedAccount,
  payees,
  categoryGroups,
  disabled,
  focusNonce,
  onChange,
  onCancel,
  onSave,
}: {
  state: Extract<RegisterComposeState, { status: "open" }>;
  accounts: Account[];
  lockedAccount: Account | null;
  payees: Payee[];
  categoryGroups: CategoryGroup[];
  disabled: boolean;
  focusNonce: number;
  onChange: (next: RegisterComposeState) => void;
  onCancel: () => void;
  onSave: (keepOpen: boolean) => void;
}) {
  const dateRef = useRef<HTMLInputElement>(null);
  const orderedGroups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const transfer = findTransferPayee(payees, state.draft.payeeName);
  const busy = state.saving || disabled;

  useEffect(() => {
    dateRef.current?.focus();
  }, [focusNonce]);

  const patch = (draft: {
    date?: string;
    accountId?: string;
    payeeName?: string;
    categoryId?: string;
    memo?: string;
    flagColor?: string;
  }) => {
    onChange(reduceCompose(state, { type: "patch", draft }));
  };

  return (
    <>
      <tr
        className="register-compose-row"
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            if (busy) {
              return;
            }
            event.preventDefault();
            onCancel();
          }
          if (event.key === "Enter" && (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement)) {
            event.preventDefault();
            if (!busy) {
              onSave(false);
            }
          }
        }}
      >
        <td className="register-select" />
        <td>
          <label className="sr-only" htmlFor="register-compose-date">Date</label>
          <input
            id="register-compose-date"
            ref={dateRef}
            type="date"
            name="date"
            value={state.draft.date}
            onChange={(event) => patch({ date: event.target.value })}
            disabled={busy}
            required
          />
        </td>
        <td>
          {lockedAccount ? (
            <span className="register-compose-locked-account">{lockedAccount.name}</span>
          ) : (
            <>
              <label className="sr-only" htmlFor="register-compose-account">Account</label>
              <select
                id="register-compose-account"
                name="account"
                value={state.draft.accountId}
                onChange={(event) => patch({ accountId: event.target.value })}
                disabled={busy}
              >
                <option value="">Choose account</option>
                {accounts.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name}
                  </option>
                ))}
              </select>
            </>
          )}
        </td>
        <td>
          <label className="sr-only" htmlFor="register-compose-payee">Payee</label>
          <input
            id="register-compose-payee"
            type="text"
            name="payee"
            list="register-compose-payees"
            value={state.draft.payeeName}
            onChange={(event) => patch({ payeeName: event.target.value })}
            onBlur={() => {
              const snapped = canonicalPayeeName(payees, state.draft.payeeName);
              if (snapped !== state.draft.payeeName) {
                patch({ payeeName: snapped });
              }
            }}
            placeholder="Payee"
            autoComplete="off"
            disabled={busy}
            required
            onKeyDown={(event) => {
              if (event.key !== "Enter") {
                return;
              }
              event.stopPropagation();
              if (event.nativeEvent.isComposing || event.keyCode === 229) {
                return;
              }
            }}
          />
          <datalist id="register-compose-payees">
            {payeeListEntries(payees, accounts, state.draft.accountId).map((entry) => (
              <option key={entry.id} value={entry.value}>
                {entry.label}
              </option>
            ))}
          </datalist>
        </td>
        <td>
          {transfer ? (
            <span className="register-compose-transfer">Transfer</span>
          ) : (
            <CategorySelect
              aria-label="Category"
              value={state.draft.categoryId}
              onChange={(categoryId) => patch({ categoryId })}
              groups={orderedGroups}
              disabled={busy}
            />
          )}
        </td>
        <td>
          <label className="sr-only" htmlFor="register-compose-memo">Memo</label>
          <input
            id="register-compose-memo"
            type="text"
            name="memo"
            value={state.draft.memo}
            onChange={(event) => patch({ memo: event.target.value })}
            placeholder="Memo"
            disabled={busy}
          />
        </td>
        <td className="num">
          <label className="sr-only" htmlFor="register-compose-outflow">Outflow</label>
          <input
            id="register-compose-outflow"
            type="text"
            inputMode="decimal"
            name="outflow"
            value={state.draft.outflow}
            onChange={(event) => onChange(reduceCompose(state, { type: "set-outflow", value: event.target.value }))}
            onBlur={() => {
              const next = formatComposeAmount(state.draft.outflow);
              if (next !== state.draft.outflow) {
                onChange(reduceCompose(state, { type: "set-outflow", value: next }));
              }
            }}
            placeholder="0.00"
            disabled={busy}
          />
        </td>
        <td className="num">
          <label className="sr-only" htmlFor="register-compose-inflow">Inflow</label>
          <input
            id="register-compose-inflow"
            type="text"
            inputMode="decimal"
            name="inflow"
            value={state.draft.inflow}
            onChange={(event) => onChange(reduceCompose(state, { type: "set-inflow", value: event.target.value }))}
            onBlur={() => {
              const next = formatComposeAmount(state.draft.inflow);
              if (next !== state.draft.inflow) {
                onChange(reduceCompose(state, { type: "set-inflow", value: next }));
              }
            }}
            placeholder="0.00"
            disabled={busy}
          />
        </td>
        <td className="register-actions" />
        <td className="register-status" />
      </tr>
      <tr className="register-compose-actions-row">
        <td colSpan={10}>
          <div className="register-compose-actions">
            <span className="field-label" id="register-compose-flag-label">Flag</span>
            <FlagPicker
              labelledBy="register-compose-flag-label"
              value={state.draft.flagColor}
              onChange={(flagColor) => patch({ flagColor })}
              disabled={busy}
            />
            <button type="button" className="register-compose-cancel" onClick={onCancel} disabled={busy}>
              Cancel
            </button>
            <button type="button" className="register-compose-save" onClick={() => onSave(false)} disabled={busy}>
              {state.saving ? "Saving…" : "Save"}
            </button>
            <button type="button" className="register-compose-save" onClick={() => onSave(true)} disabled={busy}>
              Save and add another
            </button>
          </div>
        </td>
      </tr>
      {state.error && (
        <tr className="register-compose-error-row">
          <td colSpan={10}>
            <p className="register-compose-error" role="alert">{state.error}</p>
          </td>
        </tr>
      )}
    </>
  );
}
