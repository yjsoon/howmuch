import SwiftUI

enum ScheduleFrequency: String, CaseIterable, Identifiable {
  case never
  case daily
  case weekly
  case everyOtherWeek
  case twiceAMonth
  case every4Weeks
  case monthly
  case everyOtherMonth
  case every3Months
  case every4Months
  case twiceAYear
  case yearly
  case everyOtherYear

  var id: String { rawValue }

  var title: String {
    switch self {
    case .never: "Does not repeat"
    case .daily: "Daily"
    case .weekly: "Weekly"
    case .everyOtherWeek: "Every other week"
    case .twiceAMonth: "Twice a month"
    case .every4Weeks: "Every 4 weeks"
    case .monthly: "Monthly"
    case .everyOtherMonth: "Every other month"
    case .every3Months: "Every 3 months"
    case .every4Months: "Every 4 months"
    case .twiceAYear: "Twice a year"
    case .yearly: "Yearly"
    case .everyOtherYear: "Every other year"
    }
  }
}

struct ScheduledSubtransactionDraft {
  /// Imported line IDs must survive an edit. New lines deliberately omit an
  /// ID so the API can derive one from the write's idempotency key.
  var id: String?
  var amountText: String
  var payeeID: String?
  var categoryID: String?
  var transferAccountID: String?
  var memo: String

  init(
    id: String? = nil,
    amountText: String = "0",
    payeeID: String? = nil,
    categoryID: String? = nil,
    transferAccountID: String? = nil,
    memo: String = ""
  ) {
    self.id = id
    self.amountText = amountText
    self.payeeID = payeeID
    self.categoryID = categoryID
    self.transferAccountID = transferAccountID
    self.memo = memo
  }

  init(subtransaction: ScheduledSubtransaction) {
    id = subtransaction.id
    amountText = MoneyCodec.displayString(for: subtransaction.amount, currencyFormat: nil)
    payeeID = subtransaction.payeeID
    categoryID = subtransaction.categoryID
    transferAccountID = subtransaction.transferAccountID
    memo = subtransaction.memo ?? ""
  }

  var amount: Int? {
    MoneyCodec.milliunits(from: amountText)
  }

  func writeRequest() -> ScheduledSubtransactionWriteRequest? {
    guard let amount else { return nil }
    return ScheduledSubtransactionWriteRequest(
      id: id,
      amount: amount,
      payeeID: transferAccountID == nil ? payeeID : nil,
      categoryID: transferAccountID == nil ? categoryID : nil,
      transferAccountID: transferAccountID,
      memo: memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : memo
    )
  }
}

struct ScheduledTransactionDraft {
  /// Identifies this editor session. Combined with the request content so an
  /// unchanged retry is idempotent while an amended schedule is a new write.
  let saveOperationSeed: String
  var id: String?
  var accountID = ""
  var dateFirst = Date.now
  var dateNext = Date.now
  var frequency: ScheduleFrequency = .monthly
  var direction: EntryDirection = .outflow
  var amountText = ""
  var payeeID: String?
  var transferAccountID: String?
  var categoryID: String?
  var memo = ""
  var flag: FlagColour = .none
  /// Split allocations are editable; imported IDs are retained.
  var subtransactions: [ScheduledSubtransactionDraft] = []

  init(schedule: ScheduledTransaction? = nil) {
    saveOperationSeed = UUID().uuidString
    guard let schedule else {
      return
    }
    id = schedule.id
    accountID = schedule.accountID
    dateFirst = Date(isoDateString: schedule.dateFirst) ?? .now
    dateNext = Date(isoDateString: schedule.dateNext) ?? dateFirst
    frequency = ScheduleFrequency(rawValue: schedule.frequency) ?? .monthly
    direction = schedule.amount < 0 ? .outflow : .inflow
    amountText = MoneyCodec.displayString(for: abs(schedule.amount), currencyFormat: nil)
    payeeID = schedule.payeeID
    // A split parent cannot also be a transfer. Do not offer or preserve that
    // invalid hybrid when saving an imported split schedule.
    transferAccountID = schedule.isSplit ? nil : schedule.transferAccountID
    categoryID = schedule.categoryID
    memo = schedule.memo ?? ""
    flag = FlagColour(rawValue: schedule.flagColor ?? "") ?? .none
    subtransactions = schedule.activeSubtransactions.map(ScheduledSubtransactionDraft.init)
  }

  var isSplit: Bool { !subtransactions.isEmpty }

  var signedAmount: Int? {
    if isSplit {
      var total = 0
      for line in subtransactions {
        guard let amount = line.amount else { return nil }
        total += amount
      }
      return total
    }
    guard let amount = MoneyCodec.milliunits(from: amountText) else {
      return nil
    }
    return direction == .outflow ? -amount : amount
  }

  var canSave: Bool {
    !accountID.isEmpty && signedAmount != nil && dateNext >= dateFirst && splitValidationMessage == nil
  }

  var splitValidationMessage: String? {
    guard isSplit else { return nil }
    guard subtransactions.count >= 2 else {
      return "A split schedule needs at least two lines."
    }
    guard subtransactions.allSatisfy({ $0.amount != nil }) else {
      return "Enter a signed amount for every split line."
    }
    return nil
  }

  mutating func enableSplit() {
    guard !isSplit else { return }
    let currentAmount = signedAmount ?? 0
    subtransactions = [
      ScheduledSubtransactionDraft(amountText: MoneyCodec.displayString(for: currentAmount, currencyFormat: nil)),
      ScheduledSubtransactionDraft(),
    ]
    categoryID = nil
    transferAccountID = nil
  }

  mutating func disableSplit() {
    let total = signedAmount ?? 0
    if total != 0 {
      direction = total < 0 ? .outflow : .inflow
    }
    amountText = MoneyCodec.displayString(for: abs(total), currencyFormat: nil)
    subtransactions = []
  }

  func writeRequest() -> ScheduledTransactionWriteRequest? {
    guard let amount = signedAmount, dateNext >= dateFirst, splitValidationMessage == nil else {
      return nil
    }
    return ScheduledTransactionWriteRequest(
      accountID: accountID,
      dateFirst: dateFirst.isoDateString,
      dateNext: dateNext.isoDateString,
      frequency: frequency.rawValue,
      amount: amount,
      payeeID: !isSplit && transferAccountID != nil ? nil : payeeID,
      categoryID: isSplit ? nil : categoryID,
      transferAccountID: isSplit ? nil : transferAccountID,
      memo: memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : memo,
      flagColor: flag == .none ? nil : flag.rawValue,
      subtransactions: subtransactions.compactMap { $0.writeRequest() }
    )
  }

  func idempotencyKey(for request: ScheduledTransactionWriteRequest) -> String {
    let splitLines = request.subtransactions.map {
      [$0.id ?? "", String($0.amount), $0.payeeID ?? "", $0.categoryID ?? "", $0.transferAccountID ?? "", $0.memo ?? ""]
        .joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
    let content = [
      id ?? "new", request.accountID, request.dateFirst, request.dateNext,
      request.frequency, String(request.amount), request.payeeID ?? "",
      request.categoryID ?? "", request.transferAccountID ?? "", request.memo ?? "",
      request.flagColor ?? "", splitLines,
    ].joined(separator: "\u{1D}")
    return "ios-schedule-\(saveOperationSeed)-\(stableScheduleHash(content))"
  }

  private func stableScheduleHash(_ content: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in content.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}

struct ScheduledTransactionPayload: Decodable {
  let scheduledTransaction: ScheduledTransaction
  let serverKnowledge: Int?
}

struct ScheduledTransactionWriteEnvelope: Encodable {
  let scheduledTransaction: ScheduledTransactionWriteRequest
}

struct ScheduledTransactionWriteRequest: Encodable {
  let accountID: String
  let dateFirst: String
  let dateNext: String
  let frequency: String
  let amount: Int
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let memo: String?
  let flagColor: String?
  let subtransactions: [ScheduledSubtransactionWriteRequest]
}

struct ScheduledSubtransactionWriteRequest: Encodable {
  let id: String?
  let amount: Int
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let memo: String?
}

/// Native editor for schedule parents. The backend keeps immutable imported
/// source objects and applies each mutation as a HowMuch overlay.
struct ScheduledTransactionEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ScheduledTransactionDraft
  @State private var errorMessage: String?
  @State private var isConfirmingDelete = false
  @State private var isConfirmingSplitRemoval = false
  @State private var isConfirmingEntry = false
  @State private var deleteOperationID = UUID().uuidString
  @State private var enterNowOperationID = UUID().uuidString
  @State private var entryDate: String?
  private let scheduledOccurrenceDate: String?

  init(schedule: ScheduledTransaction? = nil) {
    _draft = State(initialValue: ScheduledTransactionDraft(schedule: schedule))
    scheduledOccurrenceDate = schedule?.dateNext
  }

  private var isEditing: Bool { draft.id != nil }

  var body: some View {
    NavigationStack {
      Form {
        Section("Schedule") {
          DatePicker("First date", selection: $draft.dateFirst, displayedComponents: .date)
          DatePicker("Next date", selection: $draft.dateNext, in: draft.dateFirst..., displayedComponents: .date)
          Picker("Repeats", selection: $draft.frequency) {
            ForEach(ScheduleFrequency.allCases) { frequency in
              Text(frequency.title).tag(frequency)
            }
          }
        }

        Section("Transaction") {
          Picker("Account", selection: $draft.accountID) {
            Text("Choose account").tag("")
            ForEach(model.openAccounts) { account in
              Text(account.name).tag(account.id)
            }
          }
          if !draft.isSplit {
            Picker("Direction", selection: $draft.direction) {
              ForEach(EntryDirection.allCases) { direction in
                Text(direction.title).tag(direction)
              }
            }
            TextField("Amount", text: $draft.amountText)
              .keyboardType(.decimalPad)
          } else {
            HStack {
              Text("Scheduled total")
              Spacer()
              Text(MoneyCodec.signedDisplayString(for: draft.signedAmount ?? 0, currencyFormat: model.currencyFormat))
                .monospacedDigit()
                .foregroundStyle(Theme.registerAmountColour(draft.signedAmount ?? 0))
            }
          }
          if !draft.isSplit {
            NavigationLink {
              ScheduledPayeePicker(draft: $draft)
            } label: {
              DisclosureValueRow(
                icon: draft.transferAccountID == nil ? "person" : "arrow.left.arrow.right",
                caption: "Payee",
                value: payeeLabel,
                placeholder: "No payee"
              )
            }
            .buttonStyle(.plain)
          } else {
            LabeledContent("Payee") {
              Text(payeeLabel ?? "No payee")
                .foregroundStyle(.secondary)
            }
          }
          if !draft.isSplit, draft.transferAccountID == nil {
            NavigationLink {
              ScheduledCategoryPicker(draft: $draft)
            } label: {
              DisclosureValueRow(
                icon: "tag",
                caption: "Category",
                value: model.categoryName(forID: draft.categoryID),
                placeholder: "No category"
              )
            }
            .buttonStyle(.plain)
          }
          Toggle("Split transaction", isOn: Binding(
            get: { draft.isSplit },
            set: setSplit
          ))
        }

        if draft.isSplit {
          Section("Split allocations") {
            ForEach(draft.subtransactions.indices, id: \.self) { index in
              NavigationLink {
                ScheduledSplitLineEditor(
                  line: $draft.subtransactions[index],
                  parentAccountID: draft.accountID,
                  canRemove: draft.subtransactions.count > 2,
                  onRemove: { removeSplitLine(at: index) }
                )
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(splitLineLabel(draft.subtransactions[index]))
                      .foregroundStyle(Theme.textPrimary)
                    if !draft.subtransactions[index].memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                      Text(draft.subtransactions[index].memo)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                  }
                  Spacer()
                  Text(splitLineAmountLabel(draft.subtransactions[index]))
                    .monospacedDigit()
                    .foregroundStyle(Theme.registerAmountColour(draft.subtransactions[index].amount ?? 0))
                }
              }
            }
            Button {
              draft.subtransactions.append(ScheduledSubtransactionDraft())
            } label: {
              Label("Add split line", systemImage: "plus.circle.fill")
            }
            Text("Enter signed line amounts. The scheduled total is calculated from these lines and sent as their exact sum.")
              .font(.footnote)
              .foregroundStyle(.secondary)
            if let splitValidation = draft.splitValidationMessage {
              Text(splitValidation)
                .font(.footnote)
                .foregroundStyle(Theme.outflow)
                .accessibilityLabel("Split validation: \(splitValidation)")
            }
          }
        }

        if let scheduledOccurrenceDate, let scheduleID = draft.id {
          Section("Occurrence") {
            Button {
              entryDate = Date.now.isoDateString
              isConfirmingEntry = true
            } label: {
              Label("Enter Now", systemImage: "checkmark.circle.fill")
            }
            .disabled(model.isSubmitting)
            .accessibilityHint("Creates this one scheduled occurrence in the register and advances the schedule.")
            Text("Enter the occurrence due \(LedgerDate.friendlyString(fromISO: scheduledOccurrenceDate)) in today's register. Unsaved edits above are not included.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .id(scheduleID)
        }

        Section("Details") {
          Picker("Flag", selection: $draft.flag) {
            ForEach(FlagColour.allCases) { flag in
              Text(flag.title).tag(flag)
            }
          }
          TextField("Memo", text: $draft.memo, axis: .vertical)
            .lineLimit(1 ... 3)
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }

        if isEditing {
          Section {
            Button("Delete Scheduled Transaction", role: .destructive) {
              isConfirmingDelete = true
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .navigationTitle(isEditing ? "Scheduled Transaction" : "New Schedule")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(!draft.canSave || model.isSubmitting)
        }
      }
      .confirmationDialog("Delete this scheduled transaction?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
        Button("Delete Scheduled Transaction", role: .destructive) {
          deleteSchedule()
        }
      }
      .confirmationDialog("Remove split allocations?", isPresented: $isConfirmingSplitRemoval, titleVisibility: .visible) {
        Button("Remove Split", role: .destructive) {
          draft.disableSplit()
        }
      } message: {
        Text("This keeps the current split total as a single scheduled transaction and removes all split-line details.")
      }
      .confirmationDialog("Enter this scheduled transaction now?", isPresented: $isConfirmingEntry, titleVisibility: .visible) {
        Button("Enter Now") {
          enterNow()
        }
      } message: {
        Text("This creates the occurrence due \(LedgerDate.friendlyString(fromISO: scheduledOccurrenceDate ?? draft.dateNext.isoDateString)) in today's register and advances the schedule. This cannot be undone here.")
      }
      .task {
        if draft.accountID.isEmpty {
          draft.accountID = model.lastUsedAccountID.flatMap { id in model.openAccounts.contains(where: { $0.id == id }) ? id : nil }
            ?? model.openAccounts.first?.id
            ?? ""
        }
      }
    }
  }

  private var payeeLabel: String? {
    if let transferAccountID = draft.transferAccountID {
      return model.account(withID: transferAccountID).map { "Transfer to \($0.name)" } ?? "Transfer"
    }
    guard let payeeID = draft.payeeID else { return nil }
    return model.payee(withID: payeeID)?.name
  }

  private func save() {
    guard draft.canSave else {
      errorMessage = draft.splitValidationMessage ?? "Choose an account, enter an amount, and keep the next date on or after the first date."
      return
    }
    errorMessage = nil
    Task {
      do {
        try await model.saveScheduledTransaction(draft)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteSchedule() {
    guard let id = draft.id else { return }
    Task {
      do {
        try await model.deleteScheduledTransaction(id: id, idempotencyKey: deleteOperationID)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func enterNow() {
    guard
      let scheduleID = draft.id,
      let occurrenceDate = scheduledOccurrenceDate,
      let enteredDate = entryDate
    else {
      return
    }
    errorMessage = nil
    Task {
      do {
        _ = try await model.enterScheduledOccurrence(
          scheduleID: scheduleID,
          occurrenceDate: occurrenceDate,
          enteredDate: enteredDate,
          idempotencyKey: enterNowOperationID
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func setSplit(_ wantsSplit: Bool) {
    if wantsSplit {
      draft.enableSplit()
    } else if draft.isSplit {
      isConfirmingSplitRemoval = true
    }
  }

  private func removeSplitLine(at index: Int) {
    guard draft.subtransactions.count > 2 else { return }
    draft.subtransactions.remove(at: index)
  }

  private func splitLineLabel(_ line: ScheduledSubtransactionDraft) -> String {
    if let transferAccountID = line.transferAccountID {
      return model.account(withID: transferAccountID).map { "Transfer to \($0.name)" } ?? "Transfer"
    }
    if let categoryName = model.categoryName(forID: line.categoryID) {
      return categoryName
    }
    if let payeeID = line.payeeID, let payee = model.payee(withID: payeeID) {
      return payee.name
    }
    return "Uncategorised"
  }

  private func splitLineAmountLabel(_ line: ScheduledSubtransactionDraft) -> String {
    guard let amount = line.amount else { return "Enter amount" }
    return MoneyCodec.signedDisplayString(for: amount, currencyFormat: model.currencyFormat)
  }
}

private struct ScheduledSplitLineEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: ScheduledSubtransactionDraft
  let parentAccountID: String
  let canRemove: Bool
  let onRemove: () -> Void

  var body: some View {
    Form {
      Section("Allocation") {
        TextField("Signed amount", text: $line.amountText)
          .keyboardType(.numbersAndPunctuation)
        Text("Use a minus sign for an outflow and a positive amount for an inflow.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if line.amount == nil {
          Text("Enter a valid signed amount.")
            .font(.footnote)
            .foregroundStyle(Theme.outflow)
            .accessibilityLabel("Split validation: enter a valid signed amount")
        }
      }

      Section("Details") {
        NavigationLink {
          ScheduledSplitPayeePicker(line: $line, parentAccountID: parentAccountID)
        } label: {
          DisclosureValueRow(
            icon: line.transferAccountID == nil ? "person" : "arrow.left.arrow.right",
            caption: "Payee",
            value: payeeLabel,
            placeholder: "No payee"
          )
        }
        .buttonStyle(.plain)

        if line.transferAccountID == nil {
          NavigationLink {
            ScheduledSplitCategoryPicker(line: $line)
          } label: {
            DisclosureValueRow(
              icon: "tag",
              caption: "Category",
              value: model.categoryName(forID: line.categoryID),
              placeholder: "No category"
            )
          }
          .buttonStyle(.plain)
        } else {
          LabeledContent("Category") {
            Text("Transfer")
              .foregroundStyle(.secondary)
          }
        }

        TextField("Memo", text: $line.memo, axis: .vertical)
          .lineLimit(1 ... 3)
      }

      Section {
        Button("Remove Split Line", role: .destructive) {
          onRemove()
          dismiss()
        }
        .disabled(!canRemove)
        if !canRemove {
          Text("A split schedule must retain at least two lines.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Split Line")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var payeeLabel: String? {
    if let transferAccountID = line.transferAccountID {
      return model.account(withID: transferAccountID).map { "Transfer to \($0.name)" } ?? "Transfer"
    }
    guard let payeeID = line.payeeID else { return nil }
    return model.payee(withID: payeeID)?.name
  }
}

private struct ScheduledSplitPayeePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: ScheduledSubtransactionDraft
  let parentAccountID: String

  var body: some View {
    List {
      Section {
        Button("No Payee") {
          line.payeeID = nil
          line.transferAccountID = nil
          dismiss()
        }
      }
      Section("Payees") {
        ForEach(model.payees.filter { !$0.isTransferPayee }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { payee in
          Button {
            line.payeeID = payee.id
            line.transferAccountID = nil
            dismiss()
          } label: {
            selectionRow(payee.name, selected: line.payeeID == payee.id && line.transferAccountID == nil)
          }
        }
      }
      Section("Transfers") {
        ForEach(model.openAccounts.filter { $0.id != parentAccountID }) { account in
          Button {
            line.payeeID = nil
            line.categoryID = nil
            line.transferAccountID = account.id
            dismiss()
          } label: {
            selectionRow("Transfer to \(account.name)", selected: line.transferAccountID == account.id)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func selectionRow(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title).foregroundStyle(Theme.textPrimary)
      Spacer()
      if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
    }
  }
}

private struct ScheduledSplitCategoryPicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: ScheduledSubtransactionDraft

  var body: some View {
    List {
      Section {
        Button("No Category") {
          line.categoryID = nil
          dismiss()
        }
      }
      ForEach(model.categoryGroups.filter { !$0.deleted }) { group in
        Section(group.name) {
          ForEach(group.categories.filter { !$0.deleted }) { category in
            Button {
              line.categoryID = category.id
              line.transferAccountID = nil
              dismiss()
            } label: {
              selectionRow(category.name, selected: line.categoryID == category.id)
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func selectionRow(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title).foregroundStyle(Theme.textPrimary)
      Spacer()
      if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
    }
  }
}

private struct ScheduledPayeePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: ScheduledTransactionDraft

  var body: some View {
    List {
      Section {
        Button("No Payee") {
          draft.payeeID = nil
          draft.transferAccountID = nil
          dismiss()
        }
      }
      Section("Payees") {
        ForEach(model.payees.filter { !$0.isTransferPayee }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { payee in
          Button {
            draft.payeeID = payee.id
            draft.transferAccountID = nil
            dismiss()
          } label: {
            selectionRow(payee.name, selected: draft.payeeID == payee.id && draft.transferAccountID == nil)
          }
        }
      }
      Section("Transfers") {
        ForEach(model.openAccounts.filter { $0.id != draft.accountID }) { account in
          Button {
            draft.payeeID = nil
            draft.transferAccountID = account.id
            draft.categoryID = nil
            dismiss()
          } label: {
            selectionRow("Transfer to \(account.name)", selected: draft.transferAccountID == account.id)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func selectionRow(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title).foregroundStyle(Theme.textPrimary)
      Spacer()
      if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
    }
  }
}

private struct ScheduledCategoryPicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: ScheduledTransactionDraft

  var body: some View {
    List {
      Section {
        Button("No Category") {
          draft.categoryID = nil
          dismiss()
        }
      }
      ForEach(model.categoryGroups.filter { !$0.deleted }) { group in
        Section(group.name) {
          ForEach(group.categories.filter { !$0.deleted }) { category in
            Button {
              draft.categoryID = category.id
              dismiss()
            } label: {
              HStack {
                Text(category.name).foregroundStyle(Theme.textPrimary)
                Spacer()
                if draft.categoryID == category.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
              }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
  }
}
