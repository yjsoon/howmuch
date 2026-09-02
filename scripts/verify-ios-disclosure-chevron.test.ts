import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { findFormDisclosureChevronFaults } from "./lib/ios-disclosure-chevron";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : path.endsWith(".swift") ? [path] : [];
  });
}

describe("form disclosure chevrons", () => {
  test("flags a Form DisclosureValueRow that still draws its own >", () => {
    const faults = findFormDisclosureChevronFaults([
      {
        path: "apps/ios/HowMuch/Views/Components.swift",
        source: `
struct DisclosureValueRow: View {
  var showsChevron = true
  var body: some View {
    HStack {
      if showsChevron {
        Image(systemName: "chevron.right")
      }
    }
  }
}
`,
      },
      {
        path: "apps/ios/HowMuch/Views/Schedule.swift",
        source: `
struct ScheduledTransactionEditorView: View {
  var body: some View {
    Form {
      NavigationLink {
        Text("picker")
      } label: {
        DisclosureValueRow(
          icon: "person",
          caption: "Payee",
          value: "Transfer to Work Refundables",
          placeholder: "No payee"
        )
      }
    }
  }
}
`,
      },
    ]);
    expect(faults).toEqual([
      expect.objectContaining({
        path: "apps/ios/HowMuch/Views/Schedule.swift",
        detail: expect.stringContaining("showsChevron: false"),
      }),
    ]);
  });

  test("does not treat a nested Form in the same file as a card editor", () => {
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
    VStack {
      DisclosureValueRow(icon: "person", caption: "Payee", value: "Cafe", placeholder: "Choose Payee")
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
`,
      },
    ]);
    expect(faults).toEqual([
      expect.objectContaining({
        path: "apps/ios/HowMuch/Views/TransactionFormView.swift",
        detail: expect.stringContaining("TransactionSplitLineEditor"),
      }),
    ]);
  });

  test("allows card rows and Form rows that hide the custom chevron", () => {
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
    VStack {
      NavigationLink {
        Text("picker")
      } label: {
        DisclosureValueRow(icon: "person", caption: "Payee", value: "Cafe", placeholder: "Choose Payee")
      }
    }
  }
}

private struct TransactionSplitLineEditor: View {
  var body: some View {
    Form {
      Text("no disclosure row")
    }
  }
}
`,
      },
      {
        path: "apps/ios/HowMuch/Views/Schedule.swift",
        source: `
struct ScheduledTransactionEditorView: View {
  var body: some View {
    Form {
      DisclosureValueRow(
        icon: "person",
        caption: "Payee",
        value: "Transfer to Work Refundables",
        placeholder: "No payee",
        showsChevron: false
      )
    }
  }
}
`,
      },
    ]);
    expect(faults).toEqual([]);
  });

  test("the iOS sources hide Form disclosure chevrons", () => {
    const iosRoot = join(root, "apps/ios");
    const faults = findFormDisclosureChevronFaults(
      walk(iosRoot).map((path) => ({
        path: relative(root, path),
        source: readFileSync(path, "utf8"),
      })),
    );
    expect(faults).toEqual([]);
  });
});
