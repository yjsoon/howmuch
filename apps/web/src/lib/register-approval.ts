import { TRANSACTION_WRITE_BATCH } from "../api/client";

export type ApprovalRow = {
  readonly id: string;
  readonly approved: boolean;
  readonly deleted: boolean;
};

export type ApprovalPlan = readonly (readonly string[])[];

export function eligibleApprovalIds(rows: readonly ApprovalRow[]): readonly string[] {
  return rows
    .filter((row) => !row.approved && !row.deleted)
    .map((row) => row.id);
}

export function planApproval(
  ids: readonly string[],
  rows: readonly ApprovalRow[],
): ApprovalPlan | null {
  const eligible = new Set(eligibleApprovalIds(rows));
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
