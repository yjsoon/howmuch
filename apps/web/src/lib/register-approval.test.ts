import { describe, expect, test } from "bun:test";
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

  test("beginApproval adds pending and rejects empty or already-pending ids", () => {
    expect(beginApproval(emptyApprovalSession(), [])).toBeNull();
    const started = beginApproval(emptyApprovalSession(), ["a", "b"]);
    expect(started).not.toBeNull();
    expect([...started!.pending]).toEqual(["a", "b"]);
    expect(started!.confirmed.size).toBe(0);
    expect(beginApproval(started!, ["b", "c"])).toBeNull();
  });

  test("finishApproval moves ids from pending to confirmed", () => {
    const started = beginApproval(emptyApprovalSession(), ["a", "b"]);
    expect(started).not.toBeNull();
    const finished = finishApproval(started!, ["a"]);
    expect([...finished.pending]).toEqual(["b"]);
    expect([...finished.confirmed]).toEqual(["a"]);
    expect(started!.pending.has("a")).toBe(true);
    expect(started!.confirmed.has("a")).toBe(false);
  });

  test("failApproval drops pending and confirms the accepted prefix", () => {
    const started = beginApproval(emptyApprovalSession(), ["a", "b", "c"]);
    expect(started).not.toBeNull();
    const interrupted = failApproval(started!, ["a", "b", "c"], 2);
    expect(interrupted.pending.size).toBe(0);
    expect([...interrupted.confirmed]).toEqual(["a", "b"]);
    expect([...failApproval(started!, ["a", "b", "c"], 0).confirmed]).toEqual([]);
  });

  test("rowLooksApproved uses the confirmed overlay", () => {
    const session = finishApproval(beginApproval(emptyApprovalSession(), ["a"])!, ["a"]);
    expect(rowLooksApproved(row("a"), session)).toBe(true);
    expect(rowLooksApproved(row("b"), session)).toBe(false);
    expect(rowLooksApproved(row("b", true), emptyApprovalSession())).toBe(true);
  });

  test("eligibleApprovalIds skips confirmed overlay rows when a session is passed", () => {
    const session = finishApproval(beginApproval(emptyApprovalSession(), ["a"])!, ["a"]);
    expect(eligibleApprovalIds([row("a"), row("d")], session)).toEqual(["d"]);
    expect(eligibleApprovalIds([row("a"), row("d")])).toEqual(["a", "d"]);
  });
});
