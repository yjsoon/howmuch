import { describe, expect, test } from "bun:test";
import {
  approveAllLabel,
  approveSelectedLabel,
  approvedToast,
  eligibleApprovalIds,
  interruptedToast,
  planApproval,
  type ApprovalRow,
} from "./register-approval";

function row(id: string, approved = false, deleted = false): ApprovalRow {
  return { id, approved, deleted };
}

describe("register approval", () => {
  test("keeps only visible unapproved, undeleted parent ids", () => {
    expect(eligibleApprovalIds([
      row("a"),
      row("b", true),
      row("c", false, true),
      row("d"),
    ])).toEqual(["a", "d"]);
  });

  test("drops missing, approved, deleted, and duplicate ids", () => {
    const plan = planApproval(
      ["d", "a", "d", "missing", "b", "c"],
      [row("a"), row("b", true), row("c", false, true), row("d")],
    );
    expect(plan).toEqual([["d", "a"]]);
    expect(planApproval(["b", "missing"], [row("b", true)])).toBeNull();
  });

  test("chunks approval plans at 100 ids", () => {
    const approvalRows = Array.from({ length: 101 }, (_, index) => row(`txn-${index}`));
    const plan = planApproval(approvalRows.map((item) => item.id), approvalRows);
    expect(plan).toHaveLength(2);
    expect(plan?.[0]).toHaveLength(100);
    expect(plan?.[1]).toEqual(["txn-100"]);
  });

  test("writes compact British approval copy", () => {
    expect(approveSelectedLabel(3)).toBe("Approve 3 selected");
    expect(approveAllLabel(3)).toBe("Approve all (3)");
    expect(approvedToast(1)).toBe("1 transaction approved.");
    expect(approvedToast(3)).toBe("3 transactions approved.");
    expect(interruptedToast(2, 1)).toBe("2 transactions approved. 1 may not have been approved.");
  });
});
