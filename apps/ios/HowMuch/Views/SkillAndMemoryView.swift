import SwiftUI

/// Settings → Intelligence → Skill & Memory: the instructions Halation reads
/// documents with, and the rules it learned from corrections. All of it is
/// stored on this device. Rules shape future proposals only; nothing here
/// changes a saved transaction.
struct SkillAndMemoryView: View {
  @Environment(AppModel.self) private var model

  @State private var editingSkill = false
  @State private var editingAccount: AccountRef?
  @State private var selectedRule: UUID?
  @State private var confirmingClear = false

  private var store: IntakeSkillStore { .shared }

  private struct AccountRef: Identifiable {
    let id: String
  }

  var body: some View {
    let skill = store.skill
    let context = IntakeRuleContext.make(model: model)
    let rules = skill.rules.sorted { $0.createdAt > $1.createdAt }
    List {
      Section {
        Label("Stored on this \(UIDevice.current.model)", systemImage: "iphone")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
      }

      Section("Skill file") {
        Button {
          editingSkill = true
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "book.closed")
              .foregroundStyle(Theme.accent)
              .frame(width: 24)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text("How to read my documents")
                .foregroundStyle(Theme.textPrimary)
              Text(skill.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            chevron
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.card)
      }

      Section("Per account") {
        if model.openAccounts.isEmpty {
          Text("No open accounts.")
            .foregroundStyle(.secondary)
            .listRowBackground(Theme.card)
        }
        ForEach(model.openAccounts) { account in
          Button {
            editingAccount = AccountRef(id: account.id)
          } label: {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                  .foregroundStyle(Theme.textPrimary)
                Text(Self.firstInstruction(skill.account(account.id)?.notes) ?? "No instructions")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer(minLength: 8)
              chevron
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(Theme.card)
        }
      }

      Section {
        if rules.isEmpty {
          Text("Nothing learned yet. After you approve a batch, Halation may offer to remember a correction.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .listRowBackground(Theme.card)
        }
        ForEach(rules) { rule in
          ruleRow(rule, context: context)
        }
      } header: {
        Text(learnedHeader(rules))
      } footer: {
        Text("Rules and instructions are text only. Rules shape future proposals; they never change saved transactions.")
      }

      Section {
        Button("Clear all memory", role: .destructive) {
          confirmingClear = true
        }
        .frame(minHeight: 44)
        .disabled(skill.rules.isEmpty && skill.suppressed.isEmpty)
        .listRowBackground(Theme.card)
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Skill & Memory")
    .navigationBarTitleDisplayMode(.large)
    .navigationDestination(item: $selectedRule) { id in
      ruleDetail(id)
    }
    .sheet(isPresented: $editingSkill) {
      NavigationStack {
        SkillFileEditorView()
      }
      .blocksCapturePresentation()
    }
    .sheet(item: $editingAccount) { reference in
      NavigationStack {
        AccountSkillEditorView(accountID: reference.id)
      }
      .blocksCapturePresentation()
    }
    .binaryConfirm(
      "Clear all memory?",
      isPresented: $confirmingClear,
      confirm: .destructive("Clear"),
      message: {
        Text("Deletes every learned rule. Your instructions stay. Saved transactions are not changed.")
      }
    ) {
      if store.clearMemory() {
        IntakeCoordinator.shared.reapplyRules(model: model)
      } else {
        model.showSaveMessage(store.saveFailureMessage("Couldn’t clear memory. Try again."), kind: .failure)
      }
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }

  /// "Learned · 3 of 4 on".
  private func learnedHeader(_ rules: [IntakeRule]) -> String {
    guard !rules.isEmpty else {
      return "Learned"
    }
    return "Learned · \(rules.filter(\.enabled).count) of \(rules.count) on"
  }

  private func ruleRow(_ rule: IntakeRule, context: IntakeRuleContext) -> some View {
    let summary = context.summary(of: rule)
    let spoken = rule.spokenSummary(accountNames: context.accountNames, categoryNames: context.categoryNames)
    return HStack(spacing: 12) {
      Button {
        selectedRule = rule.id
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(summary)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.leading)
          if rule.isOverriddenTwice {
            Text("Overridden twice · consider removing")
              .font(.subheadline)
              .foregroundStyle(Theme.uncategorised)
          } else {
            Text(rule.provenance)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "\(spoken). \(rule.isOverriddenTwice ? "Overridden twice, consider removing" : rule.provenance)"
      )
      .accessibilityHint("Opens the rule")

      Toggle(
        "Use rule: \(spoken)",
        isOn: Binding(
          get: { rule.enabled },
          set: { enabled in
            if store.setEnabled(enabled, rule: rule.id) {
              if !enabled {
                IntakeCoordinator.shared.reapplyRules(model: model)
              }
            } else {
              model.showSaveMessage(store.saveFailureMessage("Couldn’t save this change. Try again."), kind: .failure)
            }
          }
        )
      )
      .labelsHidden()
      .tint(Theme.inflow)
    }
    .listRowBackground(Theme.card)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func ruleDetail(_ id: UUID) -> some View {
    if let rule = store.skill.rules.first(where: { $0.id == id }) {
      IntakeRuleEditorView(
        mode: .existing,
        rule: rule,
        onSave: { saved in
          guard store.replace(saved) else {
            model.showSaveMessage(store.saveFailureMessage("Couldn’t save this rule. Try again."), kind: .failure)
            return false
          }
          IntakeCoordinator.shared.reapplyRules(model: model)
          return true
        },
        onDelete: {
          if store.delete(rule: id) {
            IntakeCoordinator.shared.reapplyRules(model: model)
          } else {
            model.showSaveMessage(store.saveFailureMessage("Couldn’t delete this rule. Try again."), kind: .failure)
          }
        }
      )
    } else {
      // Gone (deleted while the screen pops): nothing to show.
      Color.clear
    }
  }

  /// The first line with words in it, for the Per account list.
  static func firstInstruction(_ notes: String?) -> String? {
    notes?
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
  }
}

/// One rule as structured fields: what it matches, what it does, how far it
/// reaches, and where it came from. Used to edit a rule before it is saved
/// (from Remember this?) and to open a saved one, with Delete rule.
struct IntakeRuleEditorView: View {
  enum Mode {
    /// Not saved yet: Cancel and Remember.
    case create
    /// Saved: Save, and Delete rule.
    case existing
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let mode: Mode
  let original: IntakeRule
  /// Returns whether the rule was saved; the editor closes only when it was.
  let onSave: (IntakeRule) -> Bool
  let onDelete: (() -> Void)?

  @State private var payeeText: String
  @State private var sign: IntakeAmountSign?
  @State private var scopeChoice: IntakeRuleScopeChoice
  @State private var accountID: String
  @State private var actionKind: ActionKind
  @State private var categoryID: String?
  @State private var renameText: String
  @State private var transferAccountID: String?
  @State private var enabled: Bool
  @State private var confirmingDelete = false

  enum ActionKind: String, CaseIterable, Identifiable {
    case category
    case rename
    case transfer
    case flag

    var id: String { rawValue }

    var label: String {
      switch self {
      case .category: "Set category"
      case .rename: "Rename payee"
      case .transfer: "Treat as transfer"
      case .flag: "Flag for review"
      }
    }
  }

  init(
    mode: Mode,
    rule: IntakeRule,
    onSave: @escaping (IntakeRule) -> Bool,
    onDelete: (() -> Void)? = nil
  ) {
    self.mode = mode
    self.original = rule
    self.onSave = onSave
    self.onDelete = onDelete
    _payeeText = State(initialValue: rule.when.payeeToken ?? "")
    _sign = State(initialValue: rule.when.amountSign)
    switch rule.scope {
    case .global:
      // A global rule with a payee is a payee rule.
      _scopeChoice = State(initialValue: (rule.when.payeeToken ?? "").isEmpty ? .global : .payee)
      _accountID = State(initialValue: rule.when.accountID ?? "")
    case .account(let id):
      _scopeChoice = State(initialValue: .account)
      _accountID = State(initialValue: id)
    case .payee:
      _scopeChoice = State(initialValue: .payee)
      _accountID = State(initialValue: rule.when.accountID ?? "")
    }
    switch rule.then {
    case .setCategory(let id):
      _actionKind = State(initialValue: .category)
      _categoryID = State(initialValue: id)
      _renameText = State(initialValue: "")
      _transferAccountID = State(initialValue: nil)
    case .renamePayee(let name):
      _actionKind = State(initialValue: .rename)
      _categoryID = State(initialValue: nil)
      _renameText = State(initialValue: name)
      _transferAccountID = State(initialValue: nil)
    case .treatAsTransfer(let id):
      _actionKind = State(initialValue: .transfer)
      _categoryID = State(initialValue: nil)
      _renameText = State(initialValue: "")
      _transferAccountID = State(initialValue: id)
    case .flag:
      _actionKind = State(initialValue: .flag)
      _categoryID = State(initialValue: nil)
      _renameText = State(initialValue: "")
      _transferAccountID = State(initialValue: nil)
    }
    _enabled = State(initialValue: rule.enabled)
  }

  var body: some View {
    Form {
      Section {
        TextField("Payee, such as KOPITIAM", text: $payeeText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("Direction", selection: $sign) {
          Text("Any").tag(IntakeAmountSign?.none)
          Text("Outflow").tag(IntakeAmountSign?.some(.outflow))
          Text("Inflow").tag(IntakeAmountSign?.some(.inflow))
        }
      } header: {
        Text("When")
      } footer: {
        Text("Matches whole words in the payee: ‘grab’ does not match ‘GrabFood’.")
      }
      .listRowBackground(Theme.card)

      Section("Then") {
        Picker("Action", selection: $actionKind) {
          ForEach(ActionKind.allCases) { kind in
            Text(kind.label).tag(kind)
          }
        }
        switch actionKind {
        case .category:
          Picker("Category", selection: $categoryID) {
            Text("Choose a category").tag(String?.none)
            ForEach(categoryGroups) { group in
              Section(group.name) {
                ForEach(group.categories.filter { !$0.deleted }) { category in
                  Text(category.name).tag(String?.some(category.id))
                }
              }
            }
          }
        case .rename:
          TextField("New payee name", text: $renameText)
        case .transfer:
          Picker("Transfer to", selection: $transferAccountID) {
            Text("Choose an account").tag(String?.none)
            ForEach(model.openAccounts) { account in
              Text(account.name).tag(String?.some(account.id))
            }
          }
        case .flag:
          Text("The row is left as read and not ticked, so you check it.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .listRowBackground(Theme.card)

      Section {
        Picker("Applies to", selection: $scopeChoice) {
          if hasPayee {
            Text("All accounts").tag(IntakeRuleScopeChoice.payee)
          } else {
            // A rule with no payee (direction or account only) is the global kind.
            Text("Global").tag(IntakeRuleScopeChoice.global)
          }
          Text("One account").tag(IntakeRuleScopeChoice.account)
        }
        if scopeChoice == .account {
          Picker("Account", selection: $accountID) {
            Text("Choose an account").tag("")
            ForEach(model.openAccounts) { account in
              Text(account.name).tag(account.id)
            }
          }
        }
      } header: {
        Text("Scope")
      } footer: {
        Text("A rule for a payee and one account beats a rule for the payee alone, which beats one for the account alone.")
      }
      .listRowBackground(Theme.card)
      .onChange(of: payeeText) { _, _ in
        // A payee makes it a payee rule; with none it can only be global or for one account.
        if hasPayee, scopeChoice == .global {
          scopeChoice = .payee
        } else if !hasPayee, scopeChoice == .payee {
          scopeChoice = .global
        }
      }

      if mode == .existing {
        Section {
          Toggle("Use this rule", isOn: $enabled)
            .tint(Theme.inflow)
        }
        .listRowBackground(Theme.card)
      }

      Section("Source") {
        Text(original.provenance)
        Text(sourceText)
          .foregroundStyle(.secondary)
      }
      .listRowBackground(Theme.card)

      if mode == .existing, onDelete != nil {
        Section {
          Button("Delete rule", role: .destructive) {
            confirmingDelete = true
          }
          .frame(minHeight: 44)
        }
        .listRowBackground(Theme.card)
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle(mode == .create ? "New rule" : "Rule")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if mode == .create {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(mode == .create ? "Remember" : "Save") {
          save()
        }
        .disabled(built == nil || (mode == .existing && built == original))
        .tint(Theme.accent)
      }
    }
    .binaryConfirm(
      "Delete this rule?",
      isPresented: $confirmingDelete,
      confirm: .destructive("Delete"),
      message: {
        Text("Future documents won’t use it.")
      }
    ) {
      // Close first; the rule goes once the screen has gone, so it never shows a rule that is not there.
      let delete = onDelete
      dismiss()
      Task {
        try? await Task.sleep(for: .milliseconds(450))
        delete?()
      }
    }
  }

  /// Everyday groups first, bookkeeping groups last, as the category picker does.
  private var categoryGroups: [CategoryGroup] {
    let live = model.categoryGroups.filter { !$0.deleted }
    return live.filter { !$0.isQuiet } + live.filter(\.isQuiet)
  }

  // MARK: Source

  private var sourceText: String {
    let when = original.origin.decidedAt.formatted(.dateTime.day().month(.abbreviated))
    guard let jobID = original.origin.jobID, let job = IntakeCoordinator.shared.job(jobID) else {
      return "Decided \(when). The original batch is no longer in your Inbox."
    }
    let account = job.accountID.flatMap { id in model.accounts.first { $0.id == id }?.name }
    return "Decided \(when) in \(job.title(accountName: account))."
  }

  private var hasPayee: Bool {
    !payeeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: Building the rule

  /// The rule the fields describe, or nil while they are incomplete or could
  /// match nothing sensible (a payee with no merchant word, no condition at all).
  private var built: IntakeRule? {
    let typed = payeeText.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = IntakeRuleCondition.normalisedToken(typed)
    guard typed.isEmpty || !token.isEmpty else {
      return nil
    }
    var condition = IntakeRuleCondition(payeeToken: typed.isEmpty ? nil : token, amountSign: sign)
    let scope: IntakeRuleScope
    switch scopeChoice {
    case .global:
      scope = .global
    case .account:
      guard !accountID.isEmpty else {
        return nil
      }
      scope = .account(accountID)
      condition.accountID = accountID
    case .payee:
      guard !typed.isEmpty else {
        return nil
      }
      scope = .payee(token)
    }
    guard condition.payeeToken != nil || condition.amountSign != nil || condition.accountID != nil else {
      return nil
    }
    let action: IntakeRuleAction
    switch actionKind {
    case .category:
      guard let categoryID else {
        return nil
      }
      action = .setCategory(categoryID)
    case .rename:
      let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        return nil
      }
      action = .renamePayee(name)
    case .transfer:
      guard let transferAccountID, transferAccountID != condition.accountID else {
        return nil
      }
      action = .treatAsTransfer(transferAccountID)
    case .flag:
      action = .flag
    }
    var rule = original
    rule.scope = scope
    rule.when = condition
    rule.then = action
    rule.enabled = enabled
    return rule
  }

  private func save() {
    guard let rule = built else {
      return
    }
    if onSave(rule), mode == .existing {
      dismiss()
    }
  }
}
