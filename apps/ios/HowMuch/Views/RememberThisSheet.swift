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

  private var device: String {
    UIDevice.current.model
  }

  var body: some View {
    let context = IntakeRuleContext.make(model: model)
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

        ruleCard(context)
        if let noticed = alsoNoticed(context) {
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

        // Side by side when they fit, stacked at large text sizes.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            editButton
            justThisOnceButton
          }
          VStack(spacing: 12) {
            editButton
            justThisOnceButton
          }
        }

        Text("Saved on this \(device) · used for future documents only")
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
          save(saved)
        }
      }
      .presentationDetents([.large])
      .blocksCapturePresentation()
    }
  }

  private var editButton: some View {
    Button {
      editing = suggestion.rule(scope: scope)
    } label: {
      Text("Edit…")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .tint(Theme.accent)
  }

  private var justThisOnceButton: some View {
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

  // MARK: Rule

  private func accountName(_ context: IntakeRuleContext) -> String {
    suggestion.accountID.flatMap { context.accountNames[$0] } ?? "This account"
  }

  private func ruleCard(_ context: IntakeRuleContext) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      sentence(context)
        .font(.title3)
        .foregroundStyle(Theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      scopeMenu(context)
      Text(basis)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  /// "When the payee includes KOPITIAM, use Eating Out."
  private func sentence(_ context: IntakeRuleContext) -> Text {
    let token = Text(suggestion.token.uppercased()).bold()
    let place = scope == .account ? " on \(accountName(context))" : ""
    switch suggestion.action {
    case .setCategory(let id):
      let category = Text(context.categoryNames[id] ?? "that category").bold()
      return Text("When the payee includes \(token)\(place), use \(category).")
    case .renamePayee(let name):
      return Text("When the payee includes \(token)\(place), rename it to \(Text(name).bold()).")
    case .treatAsTransfer(let id):
      let target = Text(context.accountNames[id] ?? "another account").bold()
      return Text("When the payee includes \(token)\(place), treat it as a transfer to \(target).")
    case .flag:
      return Text("When the payee includes \(token)\(place), ask me to check it.")
    }
  }

  private func label(for choice: IntakeRuleScopeChoice, _ context: IntakeRuleContext) -> String {
    switch choice {
    case .global, .payee: "All accounts"
    case .account: "\(accountName(context)) only"
    }
  }

  /// This account, or every account. A global rule is for a rule with no payee,
  /// which the rule editor offers.
  private var choices: [IntakeRuleScopeChoice] {
    suggestion.accountID == nil ? [.payee] : [.account, .payee]
  }

  @ViewBuilder
  private func scopeMenu(_ context: IntakeRuleContext) -> some View {
    if choices.count > 1 {
      Menu {
        Picker("Scope", selection: $scope) {
          ForEach(choices) { choice in
            Text(label(for: choice, context)).tag(choice)
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text("Scope · \(label(for: scope, context))")
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
      .accessibilityValue(label(for: scope, context))
    } else {
      Text("Scope · \(label(for: scope, context))")
        .foregroundStyle(Theme.textPrimary)
        .frame(minHeight: 44, alignment: .leading)
    }
  }

  private var basis: String {
    let count = suggestion.corrections
    return "Based on \(count) \(count == 1 ? "correction" : "corrections") today"
  }

  // MARK: Also noticed

  /// The words, and the same for VoiceOver (no arrow).
  private func alsoNoticed(_ context: IntakeRuleContext) -> (text: String, spoken: String)? {
    guard let record = suggestion.alsoNoticed,
          let rule = store.skill.rules.first(where: { $0.id == record.ruleID }) else {
      return nil
    }
    let times = record.count == 1 ? "once" : "\(record.count) times"
    return (
      "\(context.summary(of: rule)) was right \(times)",
      "\(rule.spokenSummary(accountNames: context.accountNames, categoryNames: context.categoryNames)), was right \(times)"
    )
  }

  private func alsoNoticedCard(_ noticed: (text: String, spoken: String)) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("ALSO NOTICED")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline) {
        Text(noticed.text)
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Also noticed: \(noticed.spoken). Kept")
  }

  // MARK: Actions

  private func remember() {
    _ = save(suggestion.rule(scope: scope))
  }

  /// Saves the rule and closes the sheet; on failure says why and stays open.
  @discardableResult
  private func save(_ rule: IntakeRule) -> Bool {
    guard store.add(rule) else {
      model.showSaveMessage(store.saveFailureMessage("Couldn’t save this rule. Try again."), kind: .failure)
      return false
    }
    model.showSaveMessage("Rule saved on this \(device)")
    dismiss()
    return true
  }
}
