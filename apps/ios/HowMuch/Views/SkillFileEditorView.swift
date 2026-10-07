import SwiftUI

/// The skill file: structured settings the app acts on, then plain notes. The
/// notes are capped; the count shows the cost. Done saves, Cancel discards.
struct SkillFileEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var currency: String
  @State private var dateOrder: IntakeDateOrder
  @State private var window: Int
  @State private var notes: String

  private static let commonCurrencies = [
    "SGD", "MYR", "USD", "EUR", "GBP", "AUD", "NZD", "JPY", "HKD", "CNY", "IDR", "THB", "INR", "KRW",
  ]

  /// The example from docs/plans/share-intake.md section 8.
  static let exampleNotes = """
    ## Screenshots
    - GrabPay top-ups are transfers from the paying card, not spending.
    - PayNow to a person: payee is the name without "(Mobile ending …)". Ask me if it might be reimbursable.
    - A receipt for a line already in the register is a fix, not a new entry.

    ## Statements
    - Transaction date is the first date column, not the posting date.
    - CR lines are inflows.
    - Foreign spends: record the SGD charged; put "USD 12.00" in the memo.

    ## Categories
    - Food delivery is Eating Out, never Groceries.
    """

  init() {
    let skill = IntakeSkillStore.shared.skill
    _currency = State(initialValue: skill.locale.currency)
    _dateOrder = State(initialValue: skill.locale.dateOrder)
    _window = State(initialValue: skill.dedupe.dayWindow)
    _notes = State(initialValue: skill.notes)
  }

  private var isOverLimit: Bool {
    notes.count > IntakeSkill.notesLimit
  }

  private var currencies: [String] {
    Self.commonCurrencies.contains(currency) ? Self.commonCurrencies : [currency] + Self.commonCurrencies
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsCard
        SkillNotesField(text: $notes, limit: IntakeSkill.notesLimit) {
          notes += Self.example(fittingAfter: notes, limit: IntakeSkill.notesLimit)
        }
        Text("Plain instructions. Halation reads this before every document, alongside per-account notes and learned rules. Without Apple Intelligence, only the settings above and learned rules apply.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Theme.canvas)
    .navigationTitle("How to read my documents")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
        .tint(Theme.accent)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          save()
        }
        .disabled(isOverLimit)
        .tint(Theme.accent)
      }
    }
  }

  private var settingsCard: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Currency")
          .foregroundStyle(Theme.textPrimary)
        Spacer(minLength: 8)
        Menu {
          Picker("Currency", selection: $currency) {
            ForEach(currencies, id: \.self) { code in
              Text(code).tag(code)
            }
          }
        } label: {
          Text(currency)
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Currency")
        .accessibilityValue(currency)
      }
      Divider()
      HStack {
        Text("Dates")
          .foregroundStyle(Theme.textPrimary)
        Spacer(minLength: 8)
        Menu {
          Picker("Dates", selection: $dateOrder) {
            ForEach(IntakeDateOrder.allCases, id: \.self) { order in
              Text(order.label).tag(order)
            }
          }
        } label: {
          Text(dateOrder.label)
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Date order")
        .accessibilityValue(dateOrder.label)
      }
      Divider()
      Stepper(value: $window, in: IntakeSkill.dayWindowRange) {
        HStack {
          Text("Duplicate window")
            .foregroundStyle(Theme.textPrimary)
          Spacer(minLength: 8)
          Text("±\(window) \(window == 1 ? "day" : "days")")
            .font(.body.weight(.semibold))
            .monospacedDigit()
        }
      }
      .frame(minHeight: 44)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
  }

  private func save() {
    let saved = IntakeSkillStore.shared.update { skill in
      skill.locale.currency = currency
      skill.locale.dateOrder = dateOrder
      skill.dedupe.dayWindow = IntakeSkill.clampedWindow(window)
      skill.notes = String(notes.prefix(IntakeSkill.notesLimit))
    }
    if saved {
      dismiss()
    } else {
      model.showSaveMessage("Couldn’t save the skill file. Try again.", kind: .failure)
    }
  }

  /// The example, as much as fits after `existing` (whole lines only), preceded
  /// by a blank line when there is text already. Empty when nothing fits.
  static func example(fittingAfter existing: String, limit: Int) -> String {
    let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
    var room = limit - existing.count - separator.count
    guard room > 0 else {
      return ""
    }
    var kept: [Substring] = []
    for line in exampleNotes.split(separator: "\n", omittingEmptySubsequences: false) {
      let cost = line.count + (kept.isEmpty ? 0 : 1)
      if cost > room {
        break
      }
      room -= cost
      kept.append(line)
    }
    guard !kept.isEmpty else {
      return ""
    }
    return separator + kept.joined(separator: "\n")
  }
}

/// One account's instructions and duplicate window.
struct AccountSkillEditorView: View {
  let accountID: String

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var notes: String
  @State private var overridesWindow: Bool
  @State private var window: Int

  init(accountID: String) {
    self.accountID = accountID
    let skill = IntakeSkillStore.shared.skill
    let own = skill.account(accountID)
    _notes = State(initialValue: own?.notes ?? "")
    _overridesWindow = State(initialValue: own?.dedupeDayWindow != nil)
    _window = State(initialValue: own?.dedupeDayWindow ?? skill.dedupe.dayWindow)
  }

  private var accountName: String {
    model.accounts.first { $0.id == accountID }?.name ?? "Account"
  }

  private var isOverLimit: Bool {
    notes.count > IntakeSkill.accountNotesLimit
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(spacing: 0) {
          Toggle("Own duplicate window", isOn: $overridesWindow)
            .tint(Theme.accent)
            .frame(minHeight: 44)
          if overridesWindow {
            Divider()
            Stepper(value: $window, in: IntakeSkill.dayWindowRange) {
              HStack {
                Text("Duplicate window")
                  .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("±\(window) \(window == 1 ? "day" : "days")")
                  .font(.body.weight(.semibold))
                  .monospacedDigit()
              }
            }
            .frame(minHeight: 44)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

        SkillNotesField(text: $notes, limit: IntakeSkill.accountNotesLimit, onInsertExample: nil)

        Text("Applies to documents read for \(accountName). It adds to the skill file, and the duplicate window here replaces the global one.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Theme.canvas)
    .navigationTitle(accountName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
        .tint(Theme.accent)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          save()
        }
        .disabled(isOverLimit)
        .tint(Theme.accent)
      }
    }
  }

  private func save() {
    let saved = IntakeSkillStore.shared.update { skill in
      skill.setAccount(
        accountID,
        notes: notes,
        dedupeDayWindow: overridesWindow ? IntakeSkill.clampedWindow(window) : nil
      )
    }
    if saved {
      dismiss()
    } else {
      model.showSaveMessage("Couldn’t save these instructions. Try again.", kind: .failure)
    }
  }
}

/// A monospaced notes editor with a live count against its cap. The count turns
/// red over the cap, and the editors disable Done until it fits.
struct SkillNotesField: View {
  @Binding var text: String
  let limit: Int
  /// Shown as "Insert example" when set.
  var onInsertExample: (() -> Void)?

  private var isOver: Bool {
    text.count > limit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .textInputAutocapitalization(.sentences)
        .frame(minHeight: 280)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityLabel("Notes")
      HStack {
        Text("\(text.count.formatted()) / \(limit.formatted()) characters")
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(isOver ? Theme.outflow : Color.secondary)
          .accessibilityLabel(
            isOver
              ? "Over the limit: \(text.count) of \(limit) characters"
              : "\(text.count) of \(limit) characters"
          )
        Spacer(minLength: 8)
        if let onInsertExample {
          Button("Insert example", action: onInsertExample)
            .font(.subheadline)
            .tint(Theme.accent)
            .frame(minHeight: 44)
        }
      }
      .padding(.horizontal, 4)
    }
  }
}
