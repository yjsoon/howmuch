import SwiftUI

/// The skill file: structured settings the app acts on, then plain notes. The
/// notes are capped; the count shows the cost. Done saves, Cancel discards.
struct SkillFileEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  // Currency and date order are kept in the file for later but nothing reads
  // them yet, so they are not shown.
  @State private var window: Int
  @State private var notes: String
  @State private var confirmingDiscard = false

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
    _window = State(initialValue: skill.dedupe.dayWindow)
    _notes = State(initialValue: skill.notes)
  }

  private var isOverLimit: Bool {
    notes.count > IntakeSkill.notesLimit
  }

  private var isDirty: Bool {
    let skill = IntakeSkillStore.shared.skill
    return notes != skill.notes || window != skill.dedupe.dayWindow
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsCard
        SkillNotesField(text: $notes, limit: IntakeSkill.notesLimit, readLimit: IntakeSkill.promptGuidanceLimit) {
          notes += Self.example(fittingAfter: notes, limit: IntakeSkill.notesLimit)
        }
        Text("Plain instructions. Halation reads this before every document, alongside per-account notes and learned rules. Apple Intelligence reads only the first \(IntakeSkill.promptGuidanceLimit.formatted()) characters, after any notes for the account; without it, only the duplicate window and learned rules apply.")
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
    // Swiping the sheet away would lose edits; Cancel is the way out.
    .interactiveDismissDisabled(isDirty)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          if isDirty {
            confirmingDiscard = true
          } else {
            dismiss()
          }
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
    .binaryConfirm("Discard changes?", isPresented: $confirmingDiscard, confirm: .destructive("Discard")) {
      dismiss()
    }
  }

  private var settingsCard: some View {
    VStack(spacing: 0) {
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
      skill.dedupe.dayWindow = IntakeSkill.clampedWindow(window)
      skill.notes = String(notes.prefix(IntakeSkill.notesLimit))
    }
    if saved {
      dismiss()
    } else {
      model.showSaveMessage(
        IntakeSkillStore.shared.saveFailureMessage("Couldn’t save the skill file. Try again."), kind: .failure
      )
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
  @State private var confirmingDiscard = false
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

  private var isDirty: Bool {
    let own = IntakeSkillStore.shared.skill.account(accountID)
    let savedWindow = own?.dedupeDayWindow
    return notes != (own?.notes ?? "")
      || (overridesWindow ? window : nil) != savedWindow
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
    .interactiveDismissDisabled(isDirty)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          if isDirty {
            confirmingDiscard = true
          } else {
            dismiss()
          }
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
    .binaryConfirm("Discard changes?", isPresented: $confirmingDiscard, confirm: .destructive("Discard")) {
      dismiss()
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
      model.showSaveMessage(
        IntakeSkillStore.shared.saveFailureMessage("Couldn’t save these instructions. Try again."), kind: .failure
      )
    }
  }
}

/// A monospaced notes editor with a live count against its cap. The count turns
/// red over the cap, and the editors disable Done until it fits.
struct SkillNotesField: View {
  @Binding var text: String
  let limit: Int
  /// Where Apple Intelligence stops reading, when that is short of `limit`.
  /// The count says so once the text runs past it.
  var readLimit: Int?
  /// Shown as "Insert example" when set.
  var onInsertExample: (() -> Void)?

  private var isOver: Bool {
    text.count > limit
  }

  /// Nil until the text runs past what Apple Intelligence reads.
  private var readLimitExceeded: Int? {
    guard let readLimit, text.count > readLimit else {
      return nil
    }
    return readLimit
  }

  private var countText: String {
    let base = "\(text.count.formatted()) / \(limit.formatted()) characters"
    guard let read = readLimitExceeded else {
      return base
    }
    return "\(base) · up to \(read.formatted()) read"
  }

  private var countAccessibilityLabel: String {
    let base = isOver
      ? "Over the limit: \(text.count) of \(limit) characters"
      : "\(text.count) of \(limit) characters"
    guard let read = readLimitExceeded else {
      return base
    }
    return "\(base). Apple Intelligence reads at most the first \(read.formatted()) characters."
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
        Text(countText)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(isOver ? Theme.outflow : Color.secondary)
          .accessibilityLabel(countAccessibilityLabel)
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
