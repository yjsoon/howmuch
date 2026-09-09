import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import type { RewardsReport } from "../api/types";
import { RewardTile } from "../pages/Rewards";

test("historical tile separates range spend from cutoff-period minimum, not the last overlapping period", () => {
  const calculation: RewardsReport["cards"][number]["calculation"] = {
    period: "2026-02-13:2026-02-25", total_spend: 44, counted_spend: 44, eligible_spend: 40,
    reward_earned: 48, reward_earned_dollars: 0.96, reward_type: "miles",
    minimum_spend: 100, minimum_spend_met: true, minimum_spend_progress: 100,
    maximum_spend: null, maximum_spend_progress: null, maximum_spend_exceeded: false, flags: [],
  };
  const row: RewardsReport["cards"][number] = {
    card: { id: "travel", name: "Travel", issuer: "Bank", type: "miles", ynabAccountId: "account", featured: true },
    account_id: "account", account_name: "Account",
    calculation: { ...calculation, periods: [
      { start: "2026-02-01", end: "2026-02-28", calculation: { ...calculation, total_spend: 167 } },
      { start: "2026-02-10", end: "2026-02-20", calculation: { ...calculation, total_spend: 999 } },
    ] },
  };
  const html = renderToStaticMarkup(createElement(MemoryRouter, null,
    createElement(RewardTile, { row, search: "", asOf: "2026-02-25" })));
  expect(html).toContain("44.00</dd>");
  expect(html).toContain("Full-period minimum met");
  expect(html).toContain("167.00 / 100.00");
  expect(html).not.toContain("44.00 / 100.00");
  expect(html).not.toContain("999.00 / 100.00");
});
