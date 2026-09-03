import { describe, expect, test } from "bun:test";
import {
  asOfTodayBalance,
  dateInRegisterWindow,
  isUpcomingRegisterDate,
  partitionRegisterDates,
  registerFetchUntilDate,
} from "./register-current";

const TODAY = "2026-09-01";

describe("isUpcomingRegisterDate", () => {
  test("treats dates after today as upcoming, not current", () => {
    expect(isUpcomingRegisterDate("2026-09-08", TODAY)).toBe(true);
    expect(isUpcomingRegisterDate("2026-09-01", TODAY)).toBe(false);
    expect(isUpcomingRegisterDate("2026-08-29", TODAY)).toBe(false);
  });
});

describe("registerFetchUntilDate", () => {
  test("drops until_date when the window ends today or later, so posted futures load", () => {
    expect(registerFetchUntilDate("2026-09-01", TODAY)).toBeUndefined();
    expect(registerFetchUntilDate("2026-09-30", TODAY)).toBeUndefined();
    expect(registerFetchUntilDate(undefined, TODAY)).toBeUndefined();
  });

  test("keeps until_date for a past window", () => {
    expect(registerFetchUntilDate("2026-08-31", TODAY)).toBe("2026-08-31");
  });
});

describe("dateInRegisterWindow", () => {
  test("includes posted futures when the window ends today", () => {
    expect(dateInRegisterWindow("2026-09-08", "2026-07-01", "2026-09-01", TODAY)).toBe(true);
    expect(dateInRegisterWindow("2026-08-29", "2026-07-01", "2026-09-01", TODAY)).toBe(true);
    expect(dateInRegisterWindow("2026-06-01", "2026-07-01", "2026-09-01", TODAY)).toBe(false);
  });

  test("excludes posted futures from a past month window", () => {
    expect(dateInRegisterWindow("2026-09-08", "2026-08-01", "2026-08-31", TODAY)).toBe(false);
    expect(dateInRegisterWindow("2026-08-15", "2026-08-01", "2026-08-31", TODAY)).toBe(true);
  });
});

describe("asOfTodayBalance", () => {
  test("excludes future-dated rows from the headline current balance", () => {
    const working = -206_590;
    const current = asOfTodayBalance(working, [
      { account_id: "joey", date: "2026-09-08", amount: 435_160, deleted: false },
      { account_id: "joey", date: "2026-08-29", amount: -7_710, deleted: false },
      { account_id: "other", date: "2026-09-10", amount: -50_000, deleted: false },
    ], { accountId: "joey", today: TODAY });
    expect(current).toBe(working - 435_160);
  });

  test("does not subtract deleted or other-account future rows", () => {
    expect(asOfTodayBalance(1000, [
      { account_id: "joey", date: "2026-09-08", amount: -200, deleted: true },
      { account_id: "other", date: "2026-09-08", amount: -300, deleted: false },
    ], { accountId: "joey", today: TODAY })).toBe(1000);
  });
});

describe("partitionRegisterDates", () => {
  test("lists upcoming dates before current dates, each newest first", () => {
    expect(partitionRegisterDates(["2026-08-29", "2026-09-08", "2026-09-01"], TODAY)).toEqual({
      upcoming: ["2026-09-08"],
      current: ["2026-09-01", "2026-08-29"],
    });
  });
});
