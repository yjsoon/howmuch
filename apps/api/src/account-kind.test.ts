import { describe, expect, test } from "bun:test";
import {
  ACCOUNT_KINDS,
  applyAccountUpdate,
  defaultIconForKind,
  onBudgetForKind,
  parseAccountKind,
} from "./account-kind";

describe("ACCOUNT_KINDS", () => {
  test("lists the twelve HowMuch kinds with on_budget and default icons", () => {
    expect(Object.keys(ACCOUNT_KINDS)).toEqual([
      "checking",
      "savings",
      "cash",
      "creditCard",
      "lineOfCredit",
      "mortgage",
      "autoLoan",
      "studentLoan",
      "medicalDebt",
      "otherLoan",
      "otherAsset",
      "otherLiability",
    ]);
    expect(ACCOUNT_KINDS.checking).toEqual({ onBudget: true, defaultIcon: "🏦" });
    expect(ACCOUNT_KINDS.savings).toEqual({ onBudget: true, defaultIcon: "💰" });
    expect(ACCOUNT_KINDS.cash).toEqual({ onBudget: true, defaultIcon: "💵" });
    expect(ACCOUNT_KINDS.creditCard).toEqual({ onBudget: true, defaultIcon: "💳" });
    expect(ACCOUNT_KINDS.lineOfCredit).toEqual({ onBudget: true, defaultIcon: "💳" });
    expect(ACCOUNT_KINDS.mortgage).toEqual({ onBudget: false, defaultIcon: "🏠" });
    expect(ACCOUNT_KINDS.autoLoan).toEqual({ onBudget: false, defaultIcon: "🚗" });
    expect(ACCOUNT_KINDS.studentLoan).toEqual({ onBudget: false, defaultIcon: "🎓" });
    expect(ACCOUNT_KINDS.medicalDebt).toEqual({ onBudget: false, defaultIcon: "🏥" });
    expect(ACCOUNT_KINDS.otherLoan).toEqual({ onBudget: false, defaultIcon: "📄" });
    expect(ACCOUNT_KINDS.otherAsset).toEqual({ onBudget: false, defaultIcon: "📈" });
    expect(ACCOUNT_KINDS.otherLiability).toEqual({ onBudget: false, defaultIcon: "📉" });
  });
});

describe("parseAccountKind", () => {
  test("accepts table keys and rejects imported or unknown strings", () => {
    expect(parseAccountKind("savings")).toBe("savings");
    expect(parseAccountKind("mortgage")).toBe("mortgage");
    expect(parseAccountKind("payPal")).toBeNull();
    expect(parseAccountKind("personalLoan")).toBeNull();
    expect(parseAccountKind("")).toBeNull();
    expect(parseAccountKind(1)).toBeNull();
    expect(parseAccountKind(null)).toBeNull();
  });
});

describe("onBudgetForKind", () => {
  test("is true for budget kinds and false for tracking kinds", () => {
    expect(onBudgetForKind("checking")).toBe(true);
    expect(onBudgetForKind("creditCard")).toBe(true);
    expect(onBudgetForKind("mortgage")).toBe(false);
    expect(onBudgetForKind("otherAsset")).toBe(false);
  });
});

describe("defaultIconForKind", () => {
  test("uses the table default and the checking icon for unknown types", () => {
    expect(defaultIconForKind("savings")).toBe("💰");
    expect(defaultIconForKind("payPal")).toBe(ACCOUNT_KINDS.checking.defaultIcon);
    expect(defaultIconForKind(null)).toBe(ACCOUNT_KINDS.checking.defaultIcon);
  });
});

describe("applyAccountUpdate", () => {
  const checking = { name: "Everyday", icon: "🏦", type: "checking" };

  test("trims name as typed and never returns balances", () => {
    expect(applyAccountUpdate(checking, { name: "  Daily  " })).toEqual({ name: "Daily" });
  });

  test("follows the new type default when the stored icon is the old default", () => {
    expect(applyAccountUpdate(checking, { kind: "savings" })).toEqual({
      type: "savings",
      on_budget: true,
      icon: "💰",
    });
  });

  test("follows the new type default when the stored icon is missing", () => {
    expect(applyAccountUpdate({ name: "Everyday", type: "checking" }, { kind: "savings" })).toEqual({
      type: "savings",
      on_budget: true,
      icon: "💰",
    });
  });

  test("keeps a custom icon when type changes and icon is omitted", () => {
    expect(applyAccountUpdate({ name: "Everyday", icon: "🐷", type: "checking" }, { kind: "savings" })).toEqual({
      type: "savings",
      on_budget: true,
    });
  });

  test("lets an explicit icon win over the type default", () => {
    expect(applyAccountUpdate(checking, { kind: "savings", icon: "🐷" })).toEqual({
      type: "savings",
      on_budget: true,
      icon: "🐷",
    });
  });

  test("derives on_budget false when moving checking to mortgage", () => {
    expect(applyAccountUpdate(checking, { kind: "mortgage" })).toEqual({
      type: "mortgage",
      on_budget: false,
      icon: "🏠",
    });
  });

  test("follows the new type default when the previous type is imported", () => {
    expect(applyAccountUpdate({ name: "PayPal", icon: "🏦", type: "payPal" }, { kind: "otherAsset" })).toEqual({
      type: "otherAsset",
      on_budget: false,
      icon: "📈",
    });
  });
});
