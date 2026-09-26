import { expect, test } from "bun:test";
import { findFormDisclosureChevronFaults } from "./lib/ios-disclosure-chevron";

test("does not treat wrappedForm or other Form-suffixed identifiers as SwiftUI Form", () => {
  const faults = findFormDisclosureChevronFaults([
    {
      path: "apps/ios/HowMuch/Views/Components.swift",
      source: `
struct DisclosureValueRow: View {
  var showsChevron = true
  var body: some View {
    if showsChevron {
      Image(systemName: "chevron.right")
    }
  }
}
`,
    },
    {
      path: "apps/ios/HowMuch/Views/TransactionFormView.swift",
      source: `
struct TransactionFormView: View {
  var body: some View {
    wrappedForm {
      DisclosureValueRow(icon: "person", caption: "Payee", value: "Cafe", placeholder: "Choose Payee")
      DisclosureValueRow(icon: "tag", caption: "Category", value: "Food", placeholder: "Choose Category")
    }
  }

  func wrappedForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView { content() }
  }
}

struct CustomFormHost: View {
  var body: some View {
    customForm {
      DisclosureValueRow(icon: "banknote", caption: "Account", value: "Cash", placeholder: "Choose Account")
    }
  }
}

struct BuildFormHost: View {
  var body: some View {
    buildForm {
      DisclosureValueRow(icon: "calendar", caption: "Date", value: "Today", placeholder: "Choose Date")
    }
  }
}

private struct TransactionSplitLineEditor: View {
  var body: some View {
    Form {
      DisclosureValueRow(
        icon: "tag",
        caption: "Category",
        value: "Groceries",
        placeholder: "No category"
      )
    }
  }
}

struct SpacedFormEditor: View {
  var body: some View {
    Form
    {
      DisclosureValueRow(
        icon: "person",
        caption: "Payee",
        value: "Cafe",
        placeholder: "No payee"
      )
    }
  }
}
`,
    },
  ]);
  expect(faults).toEqual([
    expect.objectContaining({
      path: "apps/ios/HowMuch/Views/TransactionFormView.swift",
      detail: expect.stringContaining("TransactionSplitLineEditor"),
    }),
    expect.objectContaining({
      path: "apps/ios/HowMuch/Views/TransactionFormView.swift",
      detail: expect.stringContaining("SpacedFormEditor"),
    }),
  ]);
});
