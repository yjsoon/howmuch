import { describe, expect, test } from "bun:test";
import type { Account } from "../api/types";
import { rewardCardAccountChoices, syncedRewardCardName } from "./reward-card-accounts";

function account(partial: Partial<Account> & Pick<Account, "id" | "name" | "type">): Account {
  return {
    icon: "💳",
    on_budget: true,
    closed: false,
    balance: 0,
    cleared_balance: 0,
    uncleared_balance: 0,
    last_reconciled_date: null,
    transfer_payee_id: null,
    deleted: false,
    ...partial,
  };
}

const travel = account({ id: "acct-credit", name: "Travel Card", type: "creditCard" });
const loc = account({ id: "acct-loc", name: "Overdraft", type: "lineOfCredit" });
const everyday = account({ id: "acct-everyday", name: "Everyday Account", type: "checking" });
const closed = account({ id: "acct-old", name: "Old Card", type: "creditCard", closed: true });

describe("rewardCardAccountChoices", () => {
  test("lists unused credit cards and lines of credit, not checking", () => {
    expect(rewardCardAccountChoices([everyday, loc, travel, closed], []).map((entry) => entry.id))
      .toEqual(["acct-loc", "acct-credit", "acct-old"]);
  });

  test("drops accounts already mapped unless they are the card being edited", () => {
    expect(rewardCardAccountChoices([travel, loc], ["acct-credit"]).map((entry) => entry.id))
      .toEqual(["acct-loc"]);
    expect(rewardCardAccountChoices([travel, loc], ["acct-credit"], "acct-credit").map((entry) => entry.id))
      .toEqual(["acct-loc", "acct-credit"]);
  });
});

describe("syncedRewardCardName", () => {
  test("fills from the HowMuch card when the name is empty or still the previous account", () => {
    expect(syncedRewardCardName({ name: "", nextAccountName: "Travel Card" })).toBe("Travel Card");
    expect(syncedRewardCardName({
      name: "Travel Card",
      previousAccountName: "Travel Card",
      nextAccountName: "Overdraft",
    })).toBe("Overdraft");
  });

  test("keeps a nickname", () => {
    expect(syncedRewardCardName({
      name: "Verify cashback",
      previousAccountName: "Travel Card",
      nextAccountName: "Overdraft",
    })).toBe("Verify cashback");
  });
});
