import SwiftUI

/// Calculator semantics for the YNAB-style amount keypad. Values are
/// milliunit magnitudes; digits shift in from the right as cents.
struct AmountKeypadEngine: Equatable {
  enum Op: Equatable {
    case add
    case subtract
  }

  private var entry = 0
  private var accumulator: Int?
  private var pendingOp: Op?
  /// False right after an operator, before the second operand is typed.
  private var isTypingEntry = true

  private static let cap = 999_999_999_990

  /// What the amount header shows; matches a desk calculator's display.
  var display: Int {
    isTypingEntry ? entry : (accumulator ?? entry)
  }

  mutating func setValue(_ milliunits: Int) {
    entry = max(0, milliunits)
    accumulator = nil
    pendingOp = nil
    isTypingEntry = true
  }

  mutating func tapDigit(_ digit: Int) {
    if !isTypingEntry {
      entry = 0
      isTypingEntry = true
    }
    let next = entry * 10 + digit * 10
    entry = min(next, Self.cap)
  }

  mutating func tapBackspace() {
    if !isTypingEntry {
      cancelPendingOperation()
    }
    entry = (entry / 100) * 10
  }

  mutating func tapClear() {
    setValue(0)
  }

  mutating func tapOperator(_ op: Op) {
    if isTypingEntry, accumulator != nil {
      evaluate()
    }
    accumulator = accumulator ?? entry
    pendingOp = op
    isTypingEntry = false
  }

  mutating func tapEquals() {
    if isTypingEntry {
      evaluate()
    } else {
      cancelPendingOperation()
    }
  }

  /// Resolves any pending arithmetic and returns the final value.
  mutating func commitValue() -> Int {
    tapEquals()
    return entry
  }

  /// The value commitValue() would produce, without mutating state — so a
  /// key's label and its action can agree before the commit happens.
  var committedValue: Int {
    var copy = self
    return copy.commitValue()
  }

  private mutating func evaluate() {
    guard let acc = accumulator, let op = pendingOp else {
      return
    }
    let result = op == .add ? acc + entry : acc - entry
    entry = min(max(0, result), Self.cap)
    accumulator = nil
    pendingOp = nil
    isTypingEntry = true
  }

  private mutating func cancelPendingOperation() {
    entry = accumulator ?? entry
    accumulator = nil
    pendingOp = nil
    isTypingEntry = true
  }
}

/// "Add Transaction" sheet, seeded with the last-used account.
struct AddTransactionSheet: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TransactionFormView(draft: seededDraft, isEditing: false)
  }

  private var seededDraft: TransactionDraft {
    var draft = TransactionDraft()
    draft.seedIfNeeded(accounts: model.openAccounts, preferredAccountID: model.lastUsedAccountID)
    return draft
  }
}

/// Edit sheet for an existing transaction.
struct TransactionEditorSheet: View {
  let transaction: Transaction

  var body: some View {
    TransactionFormView(draft: TransactionDraft(transaction: transaction), isEditing: true)
  }
}

/// What the keypad's confirm key does next: collapse the keypad, continue to
/// the payee picker, or save outright — one downhill path from amount to done.
enum KeypadPrimaryAction {
  case done
  case next
  case save

  var title: String {
    switch self {
    case .done:
      return "done"
    case .next:
      return "next"
    case .save:
      return "save"
    }
  }
}

struct TransactionFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var draft: TransactionDraft
  @State private var keypad: AmountKeypadEngine
  @State private var isKeypadVisible: Bool
  @State private var errorMessage: String?
  @State private var isConfirmingDelete = false
  @State private var isAutoAdvancingToPayee = false
  private let isEditing: Bool

  // Plain stored properties before @State, assigned as wrapped values: the
  // shape the SDK 27 @State macro migration expects.
  init(draft: TransactionDraft, isEditing: Bool) {
    self.isEditing = isEditing
    var engine = AmountKeypadEngine()
    engine.setValue(draft.amountMagnitudeMilli)
    self.draft = draft
    self.keypad = engine
    // A duplicate arrives with its amount prefilled; opening the keypad over
    // it would just cost taps on the way to Save.
    self.isKeypadVisible = !isEditing && draft.amountMagnitudeMilli == 0
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 14) {
            amountHeader
            detailCard
            if draft.isSplit {
              splitCard
            }
            extrasCard

            if isEditing {
              Button(role: .destructive) {
                isConfirmingDelete = true
              } label: {
                Text("Delete Transaction")
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 13)
              }
              .ynabCard()
            }

            if let errorMessage {
              Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(Theme.outflow)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let problem = model.connectionProblem {
              Label(problem, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)

        if isKeypadVisible {
          CalculatorKeypad(
            engine: $keypad,
            primaryAction: keypadPrimaryAction,
            onPrimary: {
              // The first tap hides the keypad synchronously, so a fast
              // double-tap cannot run the action (and a save) twice.
              guard isKeypadVisible else {
                return
              }
              let action = keypadPrimaryAction
              draft.amountMagnitudeMilli = keypad.commitValue()
              withAnimation(.snappy) {
                isKeypadVisible = false
              }
              switch action {
              case .done:
                break
              case .next:
                isAutoAdvancingToPayee = true
              case .save:
                save()
              }
            }
          )
          .transition(.move(edge: .bottom))
        }
      }
      .background(Theme.canvas)
      .navigationDestination(isPresented: $isAutoAdvancingToPayee) {
        PayeePickerView(draft: $draft)
      }
      .navigationTitle(isEditing ? "Transaction" : "Add Transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if !isKeypadVisible {
          saveButton
            .padding(20)
        }
      }
      .confirmationDialog("Delete this transaction?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
        Button("Delete Transaction", role: .destructive) {
          deleteTransaction()
        }
      }
      .onChange(of: keypad) {
        draft.amountMagnitudeMilli = keypad.display
      }
    }
  }

  /// A fresh capture without a payee flows straight to the payee picker; a
  /// draft that is ready to go saves outright; otherwise just collapse.
  /// Judged on the committed value, so the label always matches what the tap
  /// will do once any pending arithmetic resolves.
  private var keypadPrimaryAction: KeypadPrimaryAction {
    guard !draft.accountID.isEmpty, keypad.committedValue > 0 else {
      return .done
    }
    if !isEditing, !draft.isSplit, !hasPayee {
      return .next
    }
    return .save
  }

  private var hasPayee: Bool {
    draft.payeeID != nil || !draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var amountHeader: some View {
    VStack(spacing: 14) {
      if !draft.isSplit {
        directionToggle
      }

      Button {
        guard !draft.isSplit else {
          // Split totals are the sum of their lines; the amount stays put so
          // the API's split invariant holds.
          return
        }
        withAnimation(.snappy) {
          isKeypadVisible = true
        }
      } label: {
        Text(amountDisplay)
          .font(.system(size: 40, weight: .bold))
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(displayedSignedAmount)))
          .animation(.snappy, value: displayedSignedAmount)
          .foregroundStyle(draft.direction == .outflow ? Theme.outflow : Theme.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .padding(.horizontal, 12)
    .background(
      draft.direction == .inflow ? Theme.lime : Color.clear,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .sensoryFeedback(.selection, trigger: draft.direction)
  }

  /// Signed milliunits behind the header, driving the rolling-digit motion.
  private var displayedSignedAmount: Int {
    let magnitude = isKeypadVisible ? keypad.display : draft.amountMagnitudeMilli
    return draft.direction == .outflow ? -magnitude : magnitude
  }

  private var amountDisplay: String {
    let signed = displayedSignedAmount
    let text = MoneyCodec.displayString(for: signed, currencyFormat: model.currencyFormat)
    // YNAB shows the minus even at zero while in outflow mode.
    if draft.direction == .outflow, signed == 0 {
      return "−\(text)"
    }
    return text
  }

  private var directionToggle: some View {
    HStack(spacing: 0) {
      directionSegment(.outflow)
      directionSegment(.inflow)
    }
    .padding(3)
    .background(
      draft.direction == .inflow ? Theme.limeDeep : Theme.surfaceMuted,
      in: Capsule()
    )
    .padding(.horizontal, 32)
  }

  private func directionSegment(_ direction: EntryDirection) -> some View {
    let isSelected = draft.direction == direction
    return Button {
      withAnimation(.snappy) {
        draft.direction = direction
      }
    } label: {
      Text(direction.title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
          isSelected ? AnyShapeStyle(Theme.card) : AnyShapeStyle(Color.clear),
          in: Capsule()
        )
    }
    .buttonStyle(.plain)
  }

  private var detailCard: some View {
    VStack(spacing: 0) {
      NavigationLink {
        PayeePickerView(draft: $draft)
      } label: {
        DisclosureValueRow(
          icon: "person.crop.circle",
          caption: "Payee",
          value: draft.payeeName,
          placeholder: "Choose Payee"
        )
      }
      .buttonStyle(.plain)
      CardDivider()

      if !hidesCategory {
        NavigationLink {
          CategoryPickerView(draft: $draft)
        } label: {
          DisclosureValueRow(
            icon: "tray.full",
            caption: "Category",
            value: draft.isSplit ? "Split (\(draft.subtransactions.count))" : model.categoryName(forID: draft.categoryID),
            placeholder: "Choose Category"
          )
        }
        .buttonStyle(.plain)
        .disabled(draft.isSplit)
        CardDivider()
      }

      NavigationLink {
        AccountPickerView(draft: $draft)
      } label: {
        DisclosureValueRow(
          icon: "building.columns",
          caption: "Account",
          value: model.account(withID: draft.accountID)?.name,
          placeholder: "Choose Account"
        )
      }
      .buttonStyle(.plain)
      CardDivider()

      NavigationLink {
        DateFieldView(date: $draft.date)
      } label: {
        DisclosureValueRow(
          icon: "calendar",
          caption: "Date",
          value: draft.date.formatted(date: .long, time: .omitted),
          placeholder: "Date"
        )
      }
      .buttonStyle(.plain)
    }
    .ynabCard()
  }

  /// Transfers between two budget accounts carry no category (YNAB); the row
  /// disappears rather than inviting a value the API would discard.
  private var hidesCategory: Bool {
    draft.isTransfer && model.accountsBothOnBudget(draft.accountID, draft.transferAccountID)
  }

  /// Read-only view of the split lines. Amounts stay locked so the lines
  /// keep summing to the transaction total; other fields remain editable.
  private var splitCard: some View {
    VStack(spacing: 0) {
      ForEach(draft.subtransactions, id: \.id) { line in
        HStack(spacing: 12) {
          Image(systemName: line.transferAccountID != nil ? "arrow.left.arrow.right" : "tray.full")
            .foregroundStyle(.secondary)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 2) {
            Text(splitLineTitle(line))
              .foregroundStyle(Theme.textPrimary)
            if let memo = line.memo, !memo.isEmpty {
              Text(memo)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text(MoneyCodec.displayString(for: line.amount, currencyFormat: model.currencyFormat))
            .monospacedDigit()
            .foregroundStyle(line.amount < 0 ? Theme.outflow : Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        if line.id != draft.subtransactions.last?.id {
          CardDivider()
        }
      }

      CardDivider()
      Text("Split lines keep the total; edit payee, date, memo and flag here.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    .ynabCard()
  }

  private func splitLineTitle(_ line: Subtransaction) -> String {
    if line.transferAccountID != nil {
      return line.payeeName ?? "Transfer"
    }
    return line.categoryName ?? "Uncategorised"
  }

  private var extrasCard: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "c.circle")
          .foregroundStyle(draft.isCleared ? Theme.inflow : Color.secondary)
          .frame(width: 28)
        Toggle("Cleared", isOn: $draft.isCleared)
          .tint(Theme.inflow)
          .foregroundStyle(Theme.textPrimary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      CardDivider()

      HStack(spacing: 12) {
        Image(systemName: draft.flag == .none ? "flag" : "flag.fill")
          .foregroundStyle(Theme.flagColour(named: draft.flag.rawValue) ?? .secondary)
          .frame(width: 28)
        Text("Flag")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Picker("Flag", selection: $draft.flag) {
          ForEach(FlagColour.allCases) { flag in
            Text(flag.title).tag(flag)
          }
        }
        .tint(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      CardDivider()

      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "note.text")
          .foregroundStyle(.secondary)
          .frame(width: 28)
        TextField("Enter a memo…", text: $draft.memo, axis: .vertical)
          .lineLimit(1 ... 3)
          .foregroundStyle(Theme.textPrimary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
    }
    .ynabCard()
  }

  private var saveButton: some View {
    Button(action: save) {
      HStack(spacing: 8) {
        if model.isSubmitting {
          ProgressView()
            .tint(.white)
        } else {
          Image(systemName: "checkmark.circle.fill")
        }
        Text("Save")
          .fontWeight(.semibold)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .buttonStyle(.glassProminent)
    .tint(Theme.accent)
    .disabled(!draft.canSave || model.isSubmitting)
    .opacity(draft.canSave ? 1 : 0.5)
  }

  private func save() {
    guard !model.isSubmitting else {
      return
    }
    draft.amountMagnitudeMilli = keypad.commitValue()
    if hidesCategory {
      // The row is hidden, so a category left over from an earlier account
      // choice would be sent (and discarded) invisibly.
      draft.categoryID = nil
    }
    errorMessage = nil
    Task {
      do {
        try await model.saveTransaction(draft)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteTransaction() {
    guard let id = draft.id,
          let transaction = model.transactions.first(where: { $0.id == id }) else {
      return
    }
    Task {
      do {
        try await model.deleteTransaction(transaction)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

struct CalculatorKeypad: View {
  @Binding var engine: AmountKeypadEngine
  let primaryAction: KeypadPrimaryAction
  let onPrimary: () -> Void

  // Tap counters exist purely to trigger haptics: light ticks for digits,
  // a firmer tap for operators and done, like a physical calculator.
  @State private var digitTaps = 0
  @State private var symbolTaps = 0

  var body: some View {
    VStack(spacing: 4) {
      keypadRow {
        digitKey(7); digitKey(8); digitKey(9)
        symbolKey("minus") { engine.tapOperator(.subtract) }
      }
      keypadRow {
        digitKey(4); digitKey(5); digitKey(6)
        symbolKey("plus") { engine.tapOperator(.add) }
      }
      keypadRow {
        digitKey(1); digitKey(2); digitKey(3)
        symbolKey("equal") { engine.tapEquals() }
      }
      keypadRow {
        symbolKey("xmark.circle.fill", colour: .secondary) { engine.tapClear() }
        digitKey(0)
        symbolKey("delete.left") { engine.tapBackspace() }
        primaryKey
      }
    }
    .padding(10)
    // The panel is glass; the done key stays a solid fill because glass
    // cannot sample other glass.
    .glassEffect(.regular, in: .rect(cornerRadius: 28))
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
    .sensoryFeedback(.impact(weight: .light), trigger: digitTaps)
    .sensoryFeedback(.impact(weight: .medium), trigger: symbolTaps)
  }

  private func keypadRow(@ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 4) {
      content()
    }
  }

  private func digitKey(_ digit: Int) -> some View {
    key {
      digitTaps += 1
      engine.tapDigit(digit)
    } label: {
      Text("\(digit)")
        .font(.title2.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
    }
  }

  private func symbolKey(_ systemName: String, colour: Color = Theme.accent, action: @escaping () -> Void) -> some View {
    key {
      symbolTaps += 1
      action()
    } label: {
      Image(systemName: systemName)
        .font(.title3.weight(.medium))
        .foregroundStyle(colour)
    }
  }

  private var primaryKey: some View {
    Button {
      symbolTaps += 1
      onPrimary()
    } label: {
      Text(primaryAction.title)
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .frame(maxWidth: .infinity)
  }

  private func key(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct DateFieldView: View {
  @Binding var date: Date
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      DatePicker("Date", selection: $date, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .tint(Theme.accent)
        .padding(.horizontal, 8)
        .ynabCard()
        .padding(16)
        .onChange(of: date) {
          dismiss()
        }
      Spacer()
    }
    .background(Theme.canvas)
    .navigationTitle("Date")
    .navigationBarTitleDisplayMode(.inline)
  }
}
