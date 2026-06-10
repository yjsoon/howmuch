import SwiftUI

struct QuickEntryView: View {
  @Environment(AppModel.self) private var model
  @State private var draft = QuickEntryDraft()
  @FocusState private var focusedField: Field?

  private enum Field {
    case payee
    case amount
    case memo
  }

  var body: some View {
    Form {
      if let error = model.lastErrorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      if let saved = model.lastSaveMessage {
        Section {
          Label(saved, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }

      Section {
        accountPicker

        DatePicker("Date", selection: $draft.date, displayedComponents: .date)

        TextField("Payee", text: $draft.payeeName)
          .textInputAutocapitalization(.words)
          .focused($focusedField, equals: .payee)
          .submitLabel(.next)
          .onSubmit { focusedField = .amount }

        TextField("Amount", text: $draft.amountText, prompt: Text("-12.34"))
          .keyboardType(.numbersAndPunctuation)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .focused($focusedField, equals: .amount)
          .submitLabel(.next)
          .onSubmit { focusedField = .memo }

        if let milliunitHint = MoneyCodec.milliunitHint(for: draft.amountText) {
          Text("Stored as \(milliunitHint).")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        TextField("Memo", text: $draft.memo, axis: .vertical)
          .lineLimit(2...4)
          .focused($focusedField, equals: .memo)

        categoryPicker
        flagPicker
        clearedPicker
      } header: {
        Text("Quick Entry")
      } footer: {
        Text("The app currently saves quick entry through `/v1/plans/{plan}/transactions` so cleared state is preserved. `/api/mobile/quick-entry` is modelled in the client, but it still cannot persist `cleared` or `approved`.")
      }

      Section {
        Button {
          Task {
            do {
              draft = try await model.submitQuickEntry(draft)
              focusedField = .payee
            } catch {
              model.lastErrorMessage = error.localizedDescription
            }
          }
        } label: {
          if model.isSubmitting {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else {
            Text("Save Transaction")
              .font(.headline)
              .frame(maxWidth: .infinity)
          }
        }
        .disabled(model.isSubmitting || !draft.canAttemptSubmit || MoneyCodec.milliunits(from: draft.amountText) == nil)
      }
    }
    .navigationTitle("Capture")
    .task(id: model.accounts.map(\.id).joined(separator: ",")) {
      draft.seedIfNeeded(accounts: model.accounts)
    }
  }

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
      ForEach(model.flattenedCategories) { category in
        Text(category.name).tag(category.id)
      }
    }
  }

  private var flagPicker: some View {
    Picker("Flag Colour", selection: $draft.flagColour) {
      ForEach(FlagColour.allCases) { flag in
        Text(flag.title).tag(flag)
      }
    }
  }

  private var clearedPicker: some View {
    Picker("Cleared State", selection: $draft.clearedState) {
      ForEach(ClearedState.allCases) { state in
        Text(state.title).tag(state)
      }
    }
    .pickerStyle(.segmented)
  }
}
