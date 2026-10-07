import SwiftUI

/// Offered once after an approval, when the owner corrected a payee or category
/// and the correction generalises. A rule is only ever created here, by an
/// explicit Remember (or Edit… then Save); never silently, never after a reject.
struct RememberThisSheet: View {
  let suggestion: IntakeRuleSuggestion

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var scope: IntakeRuleScopeChoice
  @State private var editing: IntakeRule?

  init(suggestion: IntakeRuleSuggestion) {
    self.suggestion = suggestion
    _scope = State(initialValue: suggestion.defaultScope)
  }

  private var store: IntakeSkillStore { .shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Label {
          Text("Remember this?")
            .font(.title2.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
        } icon: {
          Image(systemName: "lightbulb")
            .foregroundStyle(Theme.accent)
        }
        .accessibilityAddTraits(.isHeader)

        ruleCard
        if let noticed = alsoNoticedText {
          alsoNoticedCard(noticed)
        }

        Button {
          remember()
        } label: {
          Text("Remember")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)

        HStack(spacing: 12) {
          Button {
            editing = suggestion.rule(scope: scope)
          } label: {
            Text("Edit…")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.bordered)
          .tint(Theme.accent)

          Button {
            store.suppress(suggestion.key)
            dismiss()
          } label: {
            Text("Just this once")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.bordered)
          .tint(Theme.textPrimary)
        }

        Text("Saved on this iPhone · used for future documents only")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
      }
      .padding(16)
    }
    .background(Theme.canvas)
    .sheet(item: $editing) { rule in
      NavigationStack {
        IntakeRuleEditorView(mode: .create, rule: rule) { saved in
          if store.add(saved) {
            model.showSaveMessage("Rule saved on this iPhone")
            dismiss()
          } else {
            model.showSaveMessage("Couldn’t save this rule. Try again.", kind: .failure)
          }
        }
      }
      .presentationDetents([.large])
      .blocksCapturePresentation()
    }
  }

  // MARK: Rule

  private var context: IntakeRuleContext {
    IntakeRuleContext.make(model: model)
  }

  private var accountName: String {
    suggestion.accountID.flatMap { context.accountNames[$0] } ?? "This account"
  }

  private var ruleCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      sentence
        .font(.title3)
        .foregroundStyle(Theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      scopeMenu
      Text(basis)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  /// "When the payee is KOPITIAM, use Eating Out."
  private var sentence: Text {
    let token = Text(suggestion.token.uppercased()).bold()
    let place = scope == .account ? " on \(accountName)" : ""
    switch suggestion.action {
    case .setCategory(let id):
      let category = Text(context.categoryNames[id] ?? "that category").bold()
      return Text("When the payee is \(token)\(place), use \(category).")
    case .renamePayee(let name):
      return Text("When the payee is \(token)\(place), rename it to \(Text(name).bold()).")
    case .treatAsTransfer(let id):
      let target = Text(context.accountNames[id] ?? "another account").bold()
      return Text("When the payee is \(token)\(place), treat it as a transfer to \(target).")
    case .flag:
      return Text("When the payee is \(token)\(place), ask me to check it.")
    }
  }

  private func label(for choice: IntakeRuleScopeChoice) -> String {
    switch choice {
    case .global: "Global"
    case .account: "\(accountName) only"
    case .payee: "All accounts"
    }
  }

  private var choices: [IntakeRuleScopeChoice] {
    suggestion.accountID == nil ? [.payee, .global] : [.account, .payee, .global]
  }

  private var scopeMenu: some View {
    Menu {
      Picker("Scope", selection: $scope) {
        ForEach(choices) { choice in
          Text(label(for: choice)).tag(choice)
        }
      }
    } label: {
      HStack(spacing: 6) {
        Text("Scope · \(label(for: scope))")
          .foregroundStyle(Theme.textPrimary)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Scope")
    .accessibilityValue(label(for: scope))
  }

  private var basis: String {
    let count = suggestion.corrections
    return "Based on \(count) \(count == 1 ? "correction" : "corrections") today"
  }

  // MARK: Also noticed

  private var alsoNoticedText: String? {
    guard let record = suggestion.alsoNoticed,
          let rule = store.skill.rules.first(where: { $0.id == record.ruleID }) else {
      return nil
    }
    let times = record.count == 1 ? "once" : "\(record.count) times"
    return "\(context.summary(of: rule)) was right \(times)"
  }

  private func alsoNoticedCard(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("ALSO NOTICED")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline) {
        Text(text)
          .foregroundStyle(Theme.textPrimary)
        Spacer(minLength: 8)
        Text("Kept")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.inflow)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  // MARK: Actions

  private func remember() {
    if store.add(suggestion.rule(scope: scope)) {
      model.showSaveMessage("Rule saved on this iPhone")
      dismiss()
    } else {
      model.showSaveMessage("Couldn’t save this rule. Try again.", kind: .failure)
    }
  }
}
