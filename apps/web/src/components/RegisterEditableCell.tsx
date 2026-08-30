import { useEffect, useRef, type ReactElement, type ReactNode } from "react";
import type { Payee } from "../api/types";
import type { splitCategoryGroups } from "../lib/categories";
import { formatComposeAmount } from "../lib/register-compose";
import {
  beginCellEdit,
  cellBeginHint,
  cellGestureHandlers,
  sameCell,
  type CellEditAction,
  type CellEditContext,
  type CellEditSession,
  type RegisterCellRef,
} from "../lib/register-cell-edit";
import { CategorySelect } from "./CategorySelect";

export type CellEditSurface = {
  readonly session: CellEditSession;
  readonly context: CellEditContext;
  readonly payees: readonly Payee[];
  readonly groups: ReturnType<typeof splitCategoryGroups>;
  begin(action: Extract<CellEditAction, { type: "begin" }>): void;
  draft(value: string): void;
  commit(): void;
  cancel(): void;
};

export function RegisterEditableCell(props: {
  readonly cell: RegisterCellRef;
  readonly surface: CellEditSurface;
  readonly className?: string;
  readonly title?: string;
  readonly children: ReactNode;
}): ReactElement {
  const { cell, surface, className, title, children } = props;
  const active = surface.session.status !== "idle" && sameCell(surface.session.cell, cell);
  const committing = surface.session.status === "committing" && active;
  const draft = surface.session.status === "idle" ? "" : surface.session.draft;
  const error = surface.session.status === "editing" && sameCell(surface.session.cell, cell)
    ? surface.session.error
    : null;
  const ignoreBlurRef = useRef(false);
  const tdRef = useRef<HTMLTableCellElement>(null);
  const gesture = cellGestureHandlers(cell, surface.context, surface.begin);

  useEffect(() => {
    if (!active) {
      return;
    }
    const control = tdRef.current?.querySelector("input, select");
    if (control instanceof HTMLElement) {
      control.focus();
    }
  }, [active]);

  if (!active) {
    const decision = beginCellEdit(cell, surface.context);
    const idleTitle = decision.kind === "refuse" ? cellBeginHint(decision.reason) : title;
    return (
      <td
        ref={tdRef}
        className={className}
        title={idleTitle}
        onMouseDown={gesture.onMouseDown}
        onDoubleClick={gesture.onDoubleClick}
      >
        {children}
      </td>
    );
  }

  const classes = [className, "register-cell-editing"].filter(Boolean).join(" ");
  return (
    <td
      ref={tdRef}
      className={classes}
      title={title}
      onKeyDown={(event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          if (!committing) {
            surface.commit();
          }
        }
        if (event.key === "Escape") {
          event.preventDefault();
          if (!committing) {
            ignoreBlurRef.current = true;
            surface.cancel();
          }
        }
      }}
      onBlur={(event) => {
        if (ignoreBlurRef.current) {
          ignoreBlurRef.current = false;
          return;
        }
        const related = event.relatedTarget;
        if (related instanceof Node && event.currentTarget.contains(related)) {
          return;
        }
        if (!committing) {
          surface.commit();
        }
      }}
    >
      <CellControl
        cell={cell}
        draft={draft}
        disabled={committing}
        payees={surface.payees}
        groups={surface.groups}
        onDraft={surface.draft}
      />
      {error ? <span className="register-cell-error" aria-live="polite">{error}</span> : null}
    </td>
  );
}

function CellControl({
  cell,
  draft,
  disabled,
  payees,
  groups,
  onDraft,
}: {
  cell: RegisterCellRef;
  draft: string;
  disabled: boolean;
  payees: readonly Payee[];
  groups: CellEditSurface["groups"];
  onDraft: (value: string) => void;
}): ReactElement {
  const field = cell.field;
  if (field === "date") {
    return (
      <input
        type="date"
        aria-label="Date"
        value={draft}
        disabled={disabled}
        onChange={(event) => onDraft(event.target.value)}
      />
    );
  }
  if (field === "payee") {
    const listId = payeeListId(cell);
    return (
      <>
        <input
          type="text"
          aria-label="Payee"
          list={listId}
          value={draft}
          autoComplete="off"
          disabled={disabled}
          onChange={(event) => onDraft(event.target.value)}
        />
        <datalist id={listId}>
          {payees
            .filter((payee) => !payee.deleted && !payee.transfer_account_id)
            .map((payee) => (
              <option key={payee.id} value={payee.name} />
            ))}
        </datalist>
      </>
    );
  }
  if (field === "category") {
    return (
      <CategorySelect
        aria-label="Category"
        value={draft}
        onChange={onDraft}
        groups={groups}
        disabled={disabled}
      />
    );
  }
  if (field === "memo") {
    return (
      <input
        type="text"
        aria-label="Memo"
        value={draft}
        disabled={disabled}
        onChange={(event) => onDraft(event.target.value)}
      />
    );
  }
  return (
    <input
      type="text"
      inputMode="decimal"
      aria-label={field === "outflow" ? "Outflow" : "Inflow"}
      value={draft}
      disabled={disabled}
      onChange={(event) => onDraft(event.target.value)}
      onBlur={() => {
        const next = formatComposeAmount(draft);
        if (next !== draft) {
          onDraft(next);
        }
      }}
    />
  );
}

function payeeListId(cell: RegisterCellRef): string {
  if (cell.kind === "posted") {
    return `register-cell-payees-${cell.transaction.id}`;
  }
  return `register-cell-payees-${cell.parent.id}-${cell.lineId}`;
}
