import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function read(relativePath: string): string {
  return readFileSync(join(root, relativePath), "utf8");
}

describe("iOS add account", () => {
  test("Accounts exposes New Account and posts through the existing create route", () => {
    const accounts = read("apps/ios/HowMuch/Views/AccountsView.swift");
    const sheet = read("apps/ios/HowMuch/Views/NewAccountSheet.swift");
    const client = read("apps/ios/HowMuch/Services/APIClient.swift");
    const model = read("apps/ios/HowMuch/AppModel.swift");
    const kinds = read("apps/ios/HowMuch/Models/AccountGroups.swift");
    const pbxproj = read("apps/ios/HowMuch.xcodeproj/project.pbxproj");

    expect(accounts).toContain('Label("New Account", systemImage: "plus")');
    expect(accounts).toContain("case .newAccount:");
    expect(accounts).toContain("NewAccountSheet()");
    expect(sheet).toContain('.navigationTitle("New Account")');
    expect(sheet).toContain("model.createAccount(");
    expect(sheet).toContain("Amount owed");
    expect(sheet).toContain("Enter what you currently owe.");
    expect(sheet).toContain("Listed as");
    expect(sheet).toContain(".listStyle(.insetGrouped)");
    expect(sheet).toContain("scrollDismissesKeyboard(.interactively)");
    expect(accounts).toContain("No Accounts");
    expect(client).toContain('path: "/v1/plans/\\(planID)/accounts"');
    expect(client).toContain('method: "POST"');
    expect(model).toContain("kind.openingBalanceMilliunits(fromEntered: enteredBalance)");
    expect(kinds).toContain("storesLiability ? -abs(entered) : entered");
    expect(pbxproj).toContain("NewAccountSheet.swift in Sources");
  });
});
