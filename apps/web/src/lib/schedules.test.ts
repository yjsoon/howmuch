import { describe, expect, test } from "bun:test";
import type { ScheduledTransaction } from "../api/types";
import { activeSchedulesForAccount, scheduledAmount } from "./schedules";

describe("account register schedules", () => {
  test("keeps only active schedules for the selected account and sorts by next date", () => {
    const schedules: ScheduledTransaction[] = [
      { id: "later", account_id: "checking", date_next: "2026-10-01", amount: -2_000 },
      { id: "other", account_id: "savings", date_next: "2026-08-01", amount: -3_000 },
      { id: "deleted", account_id: "checking", date_next: "2026-07-01", amount: -4_000, deleted: true },
      { id: "sooner", account_id: "checking", date_next: "2026-09-01", amount: -1_000 },
    ];

    expect(activeSchedulesForAccount(schedules, "checking").map((schedule) => schedule.id)).toEqual(["sooner", "later"]);
  });

  test("uses the exact split total when the parent amount is absent", () => {
    expect(scheduledAmount({
      id: "split",
      subtransactions: [
        { id: "one", amount: -1_250 },
        { id: "two", amount: -2_750 },
      ],
    })).toBe(-4_000);
  });
});
