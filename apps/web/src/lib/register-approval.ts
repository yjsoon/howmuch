import { TRANSACTION_WRITE_BATCH } from "../api/client";

export type ApprovalRow = {
  readonly id: string;
  readonly approved: boolean;
  readonly deleted: boolean;
};

export type ApprovalPlan = readonly (readonly string[])[];

export type ApprovalSession = {
  readonly confirmed: ReadonlySet<string>;
  readonly pending: ReadonlySet<string>;
};

export function emptyApprovalSession(): ApprovalSession {
  return { confirmed: new Set(), pending: new Set() };
}

export function beginApproval(session: ApprovalSession, ids: readonly string[]): ApprovalSession | null {
  if (ids.length === 0 || ids.some((id) => session.pending.has(id))) {
    return null;
  }
  return {
    confirmed: new Set(session.confirmed),
    pending: new Set([...session.pending, ...ids]),
  };
}

export function finishApproval(session: ApprovalSession, ids: readonly string[]): ApprovalSession {
  const confirmed = new Set(session.confirmed);
  const pending = new Set(session.pending);
  for (const id of ids) {
    pending.delete(id);
    confirmed.add(id);
  }
  return { confirmed, pending };
}

export function failApproval(session: ApprovalSession, ids: readonly string[], approvedCount: number): ApprovalSession {
  const confirmed = new Set(session.confirmed);
  const pending = new Set(session.pending);
  for (const id of ids) {
    pending.delete(id);
  }
  for (const id of ids.slice(0, approvedCount)) {
    confirmed.add(id);
  }
  return { confirmed, pending };
}

export function rowLooksApproved(row: ApprovalRow, session: ApprovalSession): boolean {
  return row.approved || session.confirmed.has(row.id);
}

export function eligibleApprovalIds(rows: readonly ApprovalRow[], session?: ApprovalSession): readonly string[] {
  return rows
    .filter((row) => !rowLooksApproved(row, session ?? emptyApprovalSession()) && !row.deleted)
    .map((row) => row.id);
}

export function planApproval(
  ids: readonly string[],
  rows: readonly ApprovalRow[],
  session?: ApprovalSession,
): ApprovalPlan | null {
  const eligible = new Set(eligibleApprovalIds(rows, session));
  const planned: string[] = [];
  const seen = new Set<string>();
  for (const id of ids) {
    if (eligible.has(id) && !seen.has(id)) {
      seen.add(id);
      planned.push(id);
    }
  }
  if (planned.length === 0) {
    return null;
  }

  const chunks: string[][] = [];
  for (let offset = 0; offset < planned.length; offset += TRANSACTION_WRITE_BATCH) {
    chunks.push(planned.slice(offset, offset + TRANSACTION_WRITE_BATCH));
  }
  return chunks;
}

export function approveSelectedLabel(count: number): string {
  return `Approve ${count} selected`;
}

export function approveAllLabel(count: number): string {
  return `Approve all (${count})`;
}

export function approvedToast(count: number): string {
  return `${count} transaction${count === 1 ? "" : "s"} approved.`;
}

export function interruptedToast(approvedCount: number, uncertainCount: number): string {
  return `${approvedToast(approvedCount)} ${uncertainCount} may not have been approved.`;
}
