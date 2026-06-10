import SwiftUI

struct QuickEntryView: View {
  @Environment(AppModel.self) private var model
  @State private var draft = QuickEntryDraft()
  @State private var submitError: String?
  @FocusState private var focusedField: Field?

  private enum Field {
    case amount
    case payee
    case memo
  }

  var body: some View {
    Form {
      if let problem = model.connectionProblem {
        Section {
          ConnectionProblemBanner(message: problem) {
            model.requestSettingsFromCapture()
          }
        }
      }

      Section {
        amountHero
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      Section("Details") {
        TextField("Payee", text: $draft.payeeName)
          .textInputAutocapitalization(.words)
          .focused($focusedField, equals: .payee)
          .submitLabel(.next)
          .onSubmit { focusedField = .memo }

        accountPicker
        categoryPicker
        DatePicker("Date", selection: $draft.date, displayedComponents: .date)
      }

      Section("Optional") {
        TextField("Memo", text: $draft.memo, axis: .vertical)
          .lineLimit(1...3)
          .focused($focusedField, equals: .memo)

        flagPicker

        Picker("Status", selection: $draft.clearedState) {
          ForEach(ClearedState.allCases) { state in
            Text(state.title).tag(state)
          }
        }
        .pickerStyle(.segmented)
      }

      Section {
        saveButton
      } footer: {
        if let submitError {
          Label(submitError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.outflow)
        }
      }
    }
    .navigationTitle("Capture")
    .scrollDismissesKeyboard(.interactively)
    .task(id: model.accounts.map(\.id).joined(separator: ",")) {
      draft.seedIfNeeded(
        accounts: model.accounts,
        preferredAccountID: model.lastUsedAccountID,
        preferredCategoryID: model.lastUsedCategoryID
      )
    }
    .overlay(alignment: .bottom) {
      if let saved = model.lastSaveMessage {
        SaveToast(message: saved)
          .padding(.bottom, 12)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: model.lastSaveMessage)
    .sensoryFeedback(.success, trigger: model.lastSaveMessage) { _, newValue in
      newValue != nil
    }
  }

  // MARK: - Amount hero

  private var amountHero: some View {
    VStack(spacing: 14) {
      DirectionToggle(direction: $draft.direction)

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(currencySymbol)
          .font(.system(size: 26, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)

        TextField("0.00", text: $draft.amountText)
          .keyboardType(.decimalPad)
          .focused($focusedField, equals: .amount)
          .font(.system(size: 44, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(amountColour)
          .fixedSize(horizontal: true, vertical: false)
          .frame(minWidth: 60)
      }
      .frame(maxWidth: .infinity)

      if let milliunits = draft.signedMilliunits {
        Text("\(draft.direction == .spent ? "Spending" : "Receiving") \(MoneyCodec.displayString(for: abs(milliunits), currencyFormat: model.currencyFormat))")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.vertical, 8)
  }

  private var amountColour: Color {
    draft.amountText.isEmpty ? .primary : (draft.direction == .spent ? Theme.outflow : Theme.inflow)
  }

  private var currencySymbol: String {
    model.currencyFormat?.currencySymbol ?? Locale.current.currencySymbol ?? "$"
  }

  // MARK: - Pickers

  private var accountPicker: some View {
    Picker("Account", selection: $draft.accountID) {
      if draft.accountID.isEmpty {
        Text("Select account").tag("")
      }
      ForEach(model.accounts.filter { !$0.closed }) { account in
        Text(account.name).tag(account.id)
      }
    }
  }

  private var categoryPicker: some View {
    Picker("Category", selection: $draft.categoryID) {
      Text("Uncategorised").tag("")
      ForEach(model.categoryGroups.filter { !$0.hidden && !$0.deleted }) { group in
        Section(group.name) {
          ForEach(group.categories.filter { !$0.deleted }) { category in
            Text(category.name).tag(category.id)
          }
        }
      }
    }
  }

  private var flagPicker: some View {
    Picker("Flag", selection: $draft.flagColour) {
      ForEach(FlagColour.allCases) { flag in
        Text(flag.title).tag(flag)
      }
    }
  }

  // MARK: - Save

  private var saveButton: some View {
    Button {
      submit()
    } label: {
      ZStack {
        Text(saveButtonTitle)
          .font(.headline)
          .opacity(model.isSubmitting ? 0 : 1)
        if model.isSubmitting {
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, minHeight: 28)
    }
    .buttonStyle(.borderedProminent)
    .tint(draft.direction == .spent ? Theme.outflow : Theme.inflow)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets())
    .disabled(model.isSubmitting || !draft.canAttemptSubmit)
  }

  private var saveButtonTitle: String {
    guard let milliunits = draft.signedMilliunits else {
      return "Save"
    }
    return "Save \(MoneyCodec.displayString(for: abs(milliunits), currencyFormat: model.currencyFormat))"
  }

  private func submit() {
    focusedField = nil
    submitError = nil
    Task {
      do {
        draft = try await model.submitQuickEntry(draft)
      } catch {
        submitError = error.localizedDescription
      }
    }
  }
}

// MARK: - Components

private struct DirectionToggle: View {
  @Binding var direction: EntryDirection

  var body: some View {
    HStack(spacing: 4) {
      ForEach(EntryDirection.allCases) { option in
        Button {
          direction = option
        } label: {
          Text(option.title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(direction == option ? Color.white : Color.secondary)
        .background(
          Capsule().fill(direction == option ? tint(for: option) : Color.clear)
        )
      }
    }
    .padding(3)
    .background(Capsule().fill(Color(.tertiarySystemFill)))
    .frame(maxWidth: 280)
  }

  private func tint(for option: EntryDirection) -> Color {
    option == .spent ? Theme.outflow : Theme.inflow
  }
}

private struct ConnectionProblemBanner: View {
  let message: String
  let onOpenSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Cannot reach the API", systemImage: "wifi.exclamationmark")
        .font(.subheadline.weight(.semibold))
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("Check settings", action: onOpenSettings)
        .font(.footnote.weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SaveToast: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "checkmark.circle.fill")
      .font(.subheadline.weight(.medium))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Capsule().fill(Theme.inflow))
      .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
      .padding(.horizontal)
  }
}
