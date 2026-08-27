import { describe, expect, test } from "bun:test";
import {
  planIconRestoreFromYnab,
  sqlForIconRestore,
} from "./lib/restore-account-icons-from-ynab";

describe("planIconRestoreFromYnab", () => {
  test("copies a leading YNAB name emoji onto the matching HowMuch icon", () => {
    const plan = planIconRestoreFromYnab(
      [{ id: "ynab-1", name: "👍 Banana" }],
      [{ id: "ynab-1", icon: "🏦" }],
    );
    expect(plan).toMatchObject({
      ynabWithLeadingIcon: 1,
      matched: 1,
      alreadySet: 0,
      unmatchedYnabWithIcon: 0,
    });
    expect(plan.updates).toEqual([{ howmuchId: "ynab-1", icon: "👍" }]);
  });

  test("matches via external_ynab_id and keeps a trailing YNAB emoji on the name", () => {
    const plan = planIconRestoreFromYnab(
      [
        { id: "ynab-2", name: "Travel ✈️" },
        { id: "ynab-3", name: "💳 OCBC" },
      ],
      [
        { id: "local-2", external_ynab_id: "ynab-2", icon: "💳" },
        { id: "local-3", external_ynab_id: "ynab-3", icon: "🏦" },
      ],
    );
    expect(plan.updates).toEqual([{ howmuchId: "local-3", icon: "💳" }]);
    expect(plan.skippedNoIcon).toBe(1);
  });

  test("skips rows that already have the YNAB icon", () => {
    const plan = planIconRestoreFromYnab(
      [{ id: "a", name: "🐷 Savings" }],
      [{ id: "a", icon: "🐷" }],
    );
    expect(plan.updates).toEqual([]);
    expect(plan.alreadySet).toBe(1);
  });
});

describe("sqlForIconRestore", () => {
  test("writes icon updates and bumps server knowledge", () => {
    const sql = sqlForIconRestore([{ howmuchId: "acct_1", icon: "🐷" }]);
    expect(sql).toContain("UPDATE accounts SET icon = '🐷'");
    expect(sql).toContain("WHERE deleted = 0 AND id = 'acct_1'");
    expect(sql).toContain("server_knowledge = server_knowledge + 1");
  });
});
