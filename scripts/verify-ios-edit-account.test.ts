import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function read(relativePath: string): string {
  return readFileSync(join(root, relativePath), "utf8");
}

describe("iOS edit account", () => {
  test("Accounts and Register open Edit Account and PATCH type", () => {
    const accounts = read("apps/ios/HowMuch/Views/AccountsView.swift");
    const register = read("apps/ios/HowMuch/Views/RegisterView.swift");
    const edit = read("apps/ios/HowMuch/Views/EditAccountSheet.swift");
    const fields = read("apps/ios/HowMuch/Views/AccountIdentityFields.swift");
    const client = read("apps/ios/HowMuch/Services/APIClient.swift");
    const model = read("apps/ios/HowMuch/AppModel.swift");
    const pbxproj = read("apps/ios/HowMuch.xcodeproj/project.pbxproj");

    expect(edit).toContain('.navigationTitle("Edit Account")');
    expect(edit).toContain("AccountIdentityFields(");
    expect(edit).toContain("model.updateAccount(");
    expect(edit).toContain("Replaces the imported type");
    expect(edit).toContain("Balances do not change.");
    expect(fields).toContain("struct AccountIdentityFields");
    expect(fields).toContain("Text(\"Type\")");
    expect(fields).toContain("AccountKindPicker");
    expect(accounts).toContain("case .edit(");
    expect(accounts).toContain("EditAccountSheet(");
    expect(accounts).toContain('Button("Edit Account")');
    expect(accounts).toContain(".contextMenu");
    expect(register).toContain("editingAccount");
    expect(register).toContain('Label("Edit Account", systemImage: "pencil")');
    expect(register).toContain("Opens the account editor");
    expect(client).toContain("type: String?");
    expect(client).toContain("AccountUpdateRequest");
    expect(client).not.toContain("updateAccountIcon");
    expect(client).toContain("type: type");
    expect(model).toContain("func updateAccount(_ identity: AccountIdentity");
    expect(model).toContain("publishIntentCatalog()");
    expect(pbxproj).toContain("AccountIdentityFields.swift in Sources");
    expect(pbxproj).toContain("EditAccountSheet.swift in Sources");
    expect(pbxproj).toContain("A1000000000000000000007D");
    expect(pbxproj).toContain("A1000000000000000000007E");
  });
});
