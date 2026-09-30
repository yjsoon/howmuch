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

  var hasPendingArithmetic: Bool {
    pendingOp != nil
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

@MainActor
final class CaptureFormCommitHook {
  var keypad = AmountKeypadEngine()
  var hasPendingArithmetic: Bool { keypad.hasPendingArithmetic }

  @discardableResult
  func commit() -> Int {
    keypad.commitValue()
  }
}

/// Edit sheet for an existing transaction.
struct TransactionEditorSheet: View {
  let transaction: Transaction

  var body: some View {
    TransactionFormView(
      draft: TransactionDraft(transaction: transaction),
      isEditing: true,
      allowsDeletion: true
    )
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
  /// Looked up when Delete is tapped, not in the alert's message builder, which
  /// runs with every body pass (each keypad tap included).
  @State private var deleteDetail: String?
  @State private var isConfirmingEdit = false
  @State private var isConfirmingSplitRemoval = false
  @State private var isAutoAdvancingToPayee = false
  @State private var hasCommitted = false
  @State private var accountCandidates: [SlipCandidate] = []
  @State private var categoryCandidates: [SlipCandidate] = []
  @State private var showAccountPrompt = false
  @State private var showCategoryPrompt = false
  @State private var isShowingDate = false
  @State private var rewardCards: [CreditCard] = []
  /// Memo (and any later non-amount text field) — not the amount header, which
  /// owns CalculatorKeypad rather than the system keyboard.
  @FocusState private var isTextInputFocused: Bool
  private let isEditing: Bool
  private let allowsDeletion: Bool
  private let chrome: TransactionFormChrome
  private let onPersist: ((TransactionDraft) -> Void)?
  private let onDraftChange: ((TransactionDraft) -> Void)?
  private let commitHook: CaptureFormCommitHook?

  // Plain stored properties before @State, assigned as wrapped values: the
  // shape the SDK 27 @State macro migration expects.
  init(
    draft: TransactionDraft,
    isEditing: Bool,
    allowsDeletion: Bool = true,
    chrome: TransactionFormChrome = .standalone,
    onPersist: ((TransactionDraft) -> Void)? = nil,
    onDraftChange: ((TransactionDraft) -> Void)? = nil,
    commitHook: CaptureFormCommitHook? = nil
  ) {
    self.isEditing = isEditing
    self.allowsDeletion = allowsDeletion
    self.chrome = chrome
    self.onPersist = onPersist
    self.onDraftChange = onDraftChange
    self.commitHook = commitHook
    var engine = AmountKeypadEngine()
    engine.setValue(draft.amountMagnitudeMilli)
    self.draft = draft
    self.keypad = engine
    // A duplicate arrives with its amount prefilled; opening the keypad over
    // it would just cost taps on the way to Save.
    self.isKeypadVisible = !isEditing && draft.amountMagnitudeMilli == 0
  }

  var body: some View {
    wrappedForm {
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 14) {
            amountHeader
            detailCard
            splitCard
            extrasCard

            if isEditing && allowsDeletion {
              Button(role: .destructive) {
                deleteDetail = deleteConfirmationDetail
                isConfirmingDelete = true
              } label: {
                Text("Delete Transaction")
                  .foregroundStyle(Theme.cancellation)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 13)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.cardRow)
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
              withAnimation(Theme.Motion.standard) {
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
      .navigationDestination(isPresented: $isShowingDate) {
        DateFieldView(date: $draft.date)
      }
      .navigationTitle(formTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if showsStandaloneChrome {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              dismiss()
            }
            .tint(Theme.accent)
          }
        } else if chrome == .sessionEditor {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              dismiss()
            }
            .tint(Theme.accent)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              draft.amountMagnitudeMilli = keypad.commitValue()
              onPersist?(draft)
              dismiss()
            }
            .tint(Theme.accent)
          }
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if showsStandaloneChrome, !isKeypadVisible {
          saveButton
            .padding(20)
        }
      }
      .binaryConfirm(
        "Delete this transaction?",
        isPresented: $isConfirmingDelete,
        confirm: .destructive("Delete Transaction"),
        message: {
          if let deleteDetail {
            Text(deleteDetail)
          }
        }
      ) {
        deleteTransaction()
      }
      .binaryConfirm(
        "Save transaction changes?",
        isPresented: $isConfirmingEdit,
        confirm: .proceed("Save Changes"),
        message: {
          Text("This transaction or a linked transfer has been reconciled. Its status stays locked, but changing its amount, account, date, or transfer destination can make your next reconciliation inaccurate.")
        }
      ) {
        submitSave()
      }
      .binaryConfirm(
        "Remove split allocations?",
        isPresented: $isConfirmingSplitRemoval,
        confirm: .destructive("Remove Split"),
        message: {
          Text("The split lines will be replaced with their total. Their payees, categories and memos will be removed.")
        }
      ) {
        withAnimation(Theme.Motion.standard) {
          draft.disableSplit()
        }
      }
      .onChange(of: keypad) {
        commitHook?.keypad = keypad
        if keypad.hasPendingArithmetic {
          return
        }
        draft.amountMagnitudeMilli = keypad.display
      }
      .onAppear {
        commitHook?.keypad = keypad
      }
      .onChange(of: isTextInputFocused) { _, focused in
        if focused {
          collapseKeypad()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in
        collapseKeypad()
      }
      .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in
        collapseKeypad()
      }
      .task(id: model.settings.planID) {
        rewardCards = []
        if let snapshot = try? await model.apiClient.fetchRewardsTrackerSnapshot(planID: model.settings.planID) {
          rewardCards = snapshot.cards
        }
      }
      .onChange(of: draft.accountID) { _, _ in
        if !draft.accountID.isEmpty {
          accountCandidates = []
          showAccountPrompt = false
        }
      }
      .onChange(of: draft.categoryID) { _, _ in
        if draft.categoryID != nil {
          categoryCandidates = []
          showCategoryPrompt = false
        }
      }
    }
  }

  @ViewBuilder
  private func wrappedForm(@ViewBuilder content: () -> some View) -> some View {
    if chrome == .standalone {
      NavigationStack {
        content()
      }
    } else {
      content()
    }
  }

  private var showsStandaloneChrome: Bool {
    chrome == .standalone
  }

  private var formTitle: String {
    switch chrome {
    case .sessionEditor:
      return "Edit draft"
    case .standalone:
      return isEditing ? "Transaction" : "Add Transaction"
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
    if chrome == .sessionEditor {
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
          return
        }
        isTextInputFocused = false
        withAnimation(Theme.Motion.standard) {
          isKeypadVisible = true
        }
      } label: {
        Text(amountDisplay)
          .font(.system(size: 40, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(displayedSignedAmount < 0 ? Theme.outflow : Theme.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          // No numeric roll here: cents-shift entry moves every digit on
          // every keypad tap, so typed input must update instantly.
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .padding(.horizontal, 12)
    .background(
      showsInflowHeader ? Theme.lime : Color.clear,
      in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    )
    .animation(Theme.Motion.standard, value: showsInflowHeader)
    .sensoryFeedback(.selection, trigger: draft.direction)
  }

  /// Lime sits behind any inflow, including a blank one, so the header
  /// matches the lime Inflow toggle from the moment it is chosen.
  private var showsInflowHeader: Bool {
    displayedSignedAmount > 0 || (!draft.isSplit && draft.direction == .inflow)
  }

  /// Signed milliunits shown in the amount header.
  private var displayedSignedAmount: Int {
    if draft.isSplit {
      return draft.signedMilliunits
    }
    let magnitude = isKeypadVisible ? keypad.display : draft.amountMagnitudeMilli
    return draft.direction == .outflow ? -magnitude : magnitude
  }

  private var amountDisplay: String {
    let signed = displayedSignedAmount
    let text = MoneyCodec.displayString(for: signed, currencyFormat: model.currencyFormat)
    // YNAB shows the minus even at zero while in outflow mode.
    if !draft.isSplit, draft.direction == .outflow, signed == 0 {
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
      withAnimation(Theme.Motion.standard) {
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
      if draft.isSplit {
        DisclosureValueRow(
          icon: "person.crop.circle",
          caption: "Payee",
          value: "Set on each split line",
          placeholder: ""
        )
      } else {
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
      }
      CardDivider()

      if draft.isSplit {
        DisclosureValueRow(
          icon: "tray.full",
          caption: "Category",
          value: "Split (\(draft.subtransactions.count))",
          placeholder: ""
        )
        CardDivider()
      } else if !hidesCategory {
        NavigationLink {
          CategoryPickerView(draft: $draft)
        } label: {
          DisclosureValueRow(
            icon: "tray.full",
            caption: "Category",
            value: model.categoryName(forID: draft.categoryID),
            placeholder: "Choose Category"
          )
        }
        .buttonStyle(.plain)
        if showCategoryPrompt {
          ambiguousRail(
            prompt: "Which category?",
            candidates: categoryCandidates
          ) { candidate in
            draft.categoryID = candidate.id
            categoryCandidates = []
            showCategoryPrompt = false
          }
        }
        CardDivider()
      }

      NavigationLink {
        AccountPickerView(
          selectedAccountID: draft.accountID,
          // A split line transferring to this account pins the parent
          // elsewhere; the server rejects the self-transfer anyway.
          disabledAccountIDs: Set(draft.subtransactions.compactMap(\.transferAccountID))
        ) { account in
          assignPickedAccount(account.id)
        }
      } label: {
        DisclosureValueRow(
          icon: "building.columns",
          caption: "Account",
          value: model.account(withID: draft.accountID)?.name,
          placeholder: "Choose Account"
        )
      }
      .buttonStyle(.plain)
      if showAccountPrompt {
        ambiguousRail(
          prompt: "Which account?",
          candidates: accountCandidates
        ) { candidate in
          assignPickedAccount(candidate.id)
        }
      }
      CardDivider()

      Button {
        collapseKeypad()
        isShowingDate = true
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

  private func assignPickedAccount(_ accountID: String) {
    SlipAccountPick.apply(accountID, to: &draft)
    accountCandidates = []
    showAccountPrompt = false
  }

  private func collapseKeypad() {
    draft.amountMagnitudeMilli = keypad.commitValue()
    var transaction = SwiftUI.Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isKeypadVisible = false
    }
  }

  private func ambiguousRail(
    prompt: String,
    candidates: [SlipCandidate],
    onPick: @escaping (SlipCandidate) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(prompt)
        .font(.footnote)
        .foregroundStyle(Theme.uncategorised)
      if !candidates.isEmpty {
        WrappingHStack(spacing: 8) {
          ForEach(candidates) { candidate in
            Button {
              onPick(candidate)
            } label: {
              FilterChip(label: candidate.name, showsChevron: false)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(.leading, 56)
    .padding(.trailing, 16)
    .padding(.vertical, 8)
  }

  private var splitCard: some View {
    VStack(spacing: 0) {
      splitToggleRow
      if draft.isSplit {
        CardDivider()
        splitAllocations
      }
    }
    .ynabCard()
  }

  private var splitToggleRow: some View {
    HStack(spacing: 12) {
      Image(systemName: draft.isSplit ? "square.split.1x2.fill" : "square.split.1x2")
        .foregroundStyle(Theme.accent)
        .frame(width: 28)
      Toggle("Split transaction", isOn: Binding(
        get: { draft.isSplit },
        set: setSplit
      ))
      .tint(Theme.accent)
      .foregroundStyle(Theme.textPrimary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .accessibilityElement(children: .combine)
  }

  private var splitAllocations: some View {
    VStack(spacing: 0) {
      ForEach(draft.subtransactions.indices, id: \.self) { index in
        NavigationLink {
          TransactionSplitLineEditor(
            line: $draft.subtransactions[index],
            parentAccountID: draft.accountID,
            canRemove: draft.subtransactions.count > 2,
            onRemove: { removeSplitLine(at: index) }
          )
        } label: {
          HStack(spacing: 12) {
            Image(systemName: draft.subtransactions[index].transferAccountID != nil ? "arrow.left.arrow.right" : "tray.full")
              .foregroundStyle(.secondary)
              .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
              Text(splitLineTitle(draft.subtransactions[index]))
                .foregroundStyle(Theme.textPrimary)
              if let memo = draft.subtransactions[index].memo.trimmedNil {
                Text(memo)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text(splitLineAmountLabel(draft.subtransactions[index]))
              .monospacedDigit()
              .foregroundStyle((draft.subtransactions[index].amount ?? 0) < 0 ? Theme.outflow : Theme.textPrimary)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        if index < draft.subtransactions.count - 1 {
          CardDivider()
        }
      }

      CardDivider()
      Button {
        draft.subtransactions.append(TransactionSubtransactionDraft())
      } label: {
        Label("Add Split Line", systemImage: "plus")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
      CardDivider()
      VStack(alignment: .leading, spacing: 4) {
        Text("Split total: \(MoneyCodec.displayString(for: draft.signedMilliunits, currencyFormat: model.currencyFormat))")
          .font(.footnote.weight(.semibold))
        Text("Enter a signed amount on every line. Transfers pair with the selected account when saved.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if let message = draft.splitValidationMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(Theme.outflow)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
  }

  private func splitLineTitle(_ line: TransactionSubtransactionDraft) -> String {
    if let transferAccountID = line.transferAccountID {
      return model.account(withID: transferAccountID)?.name ?? "Transfer"
    }
    if let category = model.categoryName(forID: line.categoryID) {
      return category
    }
    if let payee = line.payeeName.trimmedNil {
      return payee
    }
    return "Uncategorised"
  }

  private func splitLineAmountLabel(_ line: TransactionSubtransactionDraft) -> String {
    guard let amount = line.amount else { return "Enter amount" }
    return MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat)
  }

  private func setSplit(_ shouldSplit: Bool) {
    if shouldSplit {
      withAnimation(Theme.Motion.standard) {
        draft.enableSplit()
      }
    } else if draft.isSplit {
      isConfirmingSplitRemoval = true
    }
  }

  private func removeSplitLine(at index: Int) {
    guard draft.subtransactions.count > 2, draft.subtransactions.indices.contains(index) else {
      return
    }
    draft.subtransactions.remove(at: index)
  }

  private var flagNames: [RewardFlagColour: String] {
    guard let card = rewardCards.first(where: { $0.ynabAccountId == draft.accountID }) else { return [:] }
    return RewardCardDraft.colourNames(from: card)
  }

  private var extrasCard: some View {
    VStack(spacing: 0) {
      clearedRow
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
            Text(flagNames[RewardFlagColour(ledgerColour: flag)] ?? flag.title).tag(flag)
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
          .focused($isTextInputFocused)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
    }
    .ynabCard()
  }

  /// Same Cleared switch as a new capture. Reconciled rows stay locked — the
  /// API will not accept an uncleared write after reconciliation.
  private var clearedRow: some View {
    HStack(spacing: 12) {
      Image(systemName: draft.wasReconciled ? "lock.fill" : draft.isCleared ? "c.circle.fill" : "c.circle")
        .foregroundStyle(draft.isCleared ? Theme.inflow : Color.secondary)
        .frame(width: 28)

      if draft.wasReconciled {
        VStack(alignment: .leading, spacing: 2) {
          Text("Cleared")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Reconciled")
            .foregroundStyle(Theme.textPrimary)
        }
        Spacer()
        Toggle("Cleared", isOn: .constant(true))
          .labelsHidden()
          .disabled(true)
          .tint(Theme.inflow)
      } else {
        Toggle("Cleared", isOn: $draft.isCleared)
          .tint(Theme.inflow)
          .foregroundStyle(Theme.textPrimary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
    .accessibilityValue(draft.wasReconciled ? "Reconciled" : (draft.isCleared ? "On" : "Off"))
    .accessibilityHint(draft.wasReconciled ? "Reconciled transactions stay locked." : "Marks this transaction cleared when on.")
  }

  private var deleteConfirmationDetail: String? {
    guard let id = draft.id,
          let transaction = model.transactions.first(where: { $0.id == id })
            ?? model.unapprovedTransactions.first(where: { $0.id == id }) else {
      return nil
    }
    return transaction.deleteConfirmationDetail(
      linkedReconciled: model.hasReconciledLinkedTransfer(ids: transaction.linkedTransferIDs)
    )
  }

  private var saveButton: some View {
    Button(action: save) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
        Text("Save")
          .fontWeight(.semibold)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .buttonStyle(.glassProminent)
    .tint(Theme.accent)
    .disabled(!draft.canSave || hasCommitted)
    .opacity(draft.canSave ? 1 : 0.5)
  }

  private func save() {
    guard !hasCommitted else {
      return
    }
    guard draft.splitValidationMessage == nil else {
      errorMessage = draft.splitValidationMessage
      return
    }
    draft.amountMagnitudeMilli = keypad.commitValue()
    if hidesCategory {
      draft.categoryID = nil
    }
    if draft.needsEditWarning(linkedReconciled: model.hasReconciledLinkedTransfer(ids: draft.linkedTransferIDs)) {
      isConfirmingEdit = true
      return
    }
    submitSave()
  }

  private func submitSave() {
    guard !hasCommitted else {
      return
    }
    errorMessage = nil
    do {
      if let onPersist {
        onPersist(draft)
        hasCommitted = true
        dismiss()
        return
      }
      try model.commit(draft)
      hasCommitted = true
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteTransaction() {
    guard let id = draft.id,
          let transaction = (model.transactions + model.unapprovedTransactions).first(where: { $0.id == id }) else {
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

/// Editor for one signed allocation. A split transfer is represented by its
/// target account rather than a parent-level transfer payee, which lets the
/// server create and keep the mirrored transaction paired.
private struct TransactionSplitLineEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: TransactionSubtransactionDraft
  let parentAccountID: String
  let canRemove: Bool
  let onRemove: () -> Void

  var body: some View {
    Form {
      Section("Amount") {
        TextField("Signed amount", text: $line.amountText)
          .keyboardType(.numbersAndPunctuation)
          .monospacedDigit()
        Text("Use − for spending and + for income. The parent amount is the sum of all lines.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if line.amount == nil {
          Text("Enter a valid signed amount.")
            .font(.footnote)
            .foregroundStyle(Theme.outflow)
        }
      }

      Section("Details") {
        NavigationLink {
          TransactionSplitPayeePicker(line: $line, parentAccountID: parentAccountID)
        } label: {
          splitDisclosureRow(
            icon: "person.crop.circle",
            caption: "Payee",
            value: line.transferAccountID == nil ? line.payeeName.trimmedNil : "Transfer",
            placeholder: "Choose Payee"
          )
        }

        if let transferAccountID = line.transferAccountID {
          splitDisclosureRow(
            icon: "arrow.left.arrow.right",
            caption: "Transfer",
            value: model.account(withID: transferAccountID)?.name ?? "Transfer",
            placeholder: ""
          )
        } else {
          NavigationLink {
            TransactionSplitCategoryPicker(line: $line)
          } label: {
            splitDisclosureRow(
              icon: "tray.full",
              caption: "Category",
              value: model.categoryName(forID: line.categoryID),
              placeholder: "Choose Category"
            )
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
      } footer: {
        if !canRemove {
          Text("A split transaction needs at least two lines.")
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Split Line")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func splitDisclosureRow(icon: String, caption: String, value: String?, placeholder: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(Theme.accent)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value ?? placeholder)
          .foregroundStyle(value == nil ? .secondary : Theme.textPrimary)
      }
    }
  }
}

private struct TransactionSplitPayeePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: TransactionSubtransactionDraft
  let parentAccountID: String
  @State private var searchText = ""

  var body: some View {
    List {
      if trimmedSearch.isEmpty {
        Button {
          line.payeeID = nil
          line.payeeName = ""
          line.transferAccountID = nil
          dismiss()
        } label: {
          selectionRow("No Payee", selected: line.payeeID == nil && line.payeeName.trimmedNil == nil && line.transferAccountID == nil, secondary: true)
        }
      }

      if !trimmedSearch.isEmpty, !hasExactMatch {
        Button {
          line.payeeID = nil
          line.payeeName = trimmedSearch
          line.transferAccountID = nil
          dismiss()
        } label: {
          Label("Create payee “\(trimmedSearch)”", systemImage: "plus.circle.fill")
            .foregroundStyle(Theme.accent)
        }
      }

      let payees = matchingPayees
      if !payees.isEmpty {
        Section("Payees") {
          ForEach(payees) { payee in
            Button {
              line.payeeID = payee.id
              line.payeeName = payee.name
              line.transferAccountID = nil
              dismiss()
            } label: {
              selectionRow(payee.name, selected: line.payeeID == payee.id)
            }
          }
        }
      }

      if !matchingTransferAccounts.isEmpty {
        Section("Transfers") {
          ForEach(matchingTransferAccounts) { account in
            Button {
              line.payeeID = nil
              line.payeeName = ""
              line.categoryID = nil
              line.transferAccountID = account.id
              dismiss()
            } label: {
              selectionRow(account.name, selected: line.transferAccountID == account.id)
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or add a payee")
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchingPayees: [Payee] {
    let query = trimmedSearch
    return model.payeesSortedByName.filter { payee in
      !payee.isTransferPayee && (query.isEmpty || payee.name.localizedStandardContains(query))
    }
  }

  private var matchingTransferAccounts: [Account] {
    model.openAccounts
      .filter { $0.id != parentAccountID }
      .filter { trimmedSearch.isEmpty || $0.name.localizedStandardContains(trimmedSearch) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private var hasExactMatch: Bool {
    let query = trimmedSearch
    return model.payees.contains { !$0.isTransferPayee && $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
  }

  private func selectionRow(_ title: String, selected: Bool, secondary: Bool = false) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(secondary ? Color.secondary : Theme.textPrimary)
      Spacer()
      if selected {
        Image(systemName: "checkmark")
          .foregroundStyle(Theme.accent)
      }
    }
  }
}

private struct TransactionSplitCategoryPicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var line: TransactionSubtransactionDraft
  @State private var searchText = ""

  var body: some View {
    CategorisedPickerList(
      groups: visibleGroups,
      groupTitle: { $0.name },
      items: { $0.categories.filter(categoryMatches) },
      itemTitle: { $0.name },
      isSelected: { $0.id == line.categoryID },
      searchText: $searchText,
      searchPrompt: "Search categories",
      title: "Category",
      presentsSearchOnAppear: true
    ) { category in
      line.categoryID = category.id
      line.transferAccountID = nil
      dismiss()
    } header: {
      if trimmedSearch.isEmpty {
        Button {
          line.categoryID = nil
          dismiss()
        } label: {
          PickerCheckRow(title: "No Category", isSelected: line.categoryID == nil, isSecondary: true)
        }
      }
    }
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var visibleGroups: [CategoryGroup] {
    let live = model.categoryGroups.filter { group in
      !group.deleted && group.categories.contains(where: categoryMatches)
    }
    return live.filter { !$0.isQuiet } + live.filter(\.isQuiet)
  }

  private func categoryMatches(_ category: Category) -> Bool {
    !category.deleted && (trimmedSearch.isEmpty || category.name.localizedStandardContains(trimmedSearch))
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
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
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
        .contentTransition(.interpolate)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .animation(Theme.Motion.standard, value: primaryAction.title)
    }
    .buttonStyle(.pressable)
    .frame(maxWidth: .infinity)
  }

  private func key(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
    .buttonStyle(KeypadKeyStyle())
  }
}

/// Keys light up under the finger like a physical calculator, alongside the
/// haptic tick.
private struct KeypadKeyStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
          .fill(Theme.textPrimary.opacity(configuration.isPressed ? 0.1 : 0))
      }
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

struct DateFieldView: View {
  @Binding var date: Date
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack {
      PrimedInlineDatePicker(date: $date)
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

private struct PrimedInlineDatePicker: UIViewRepresentable {
  @Binding var date: Date

  func makeCoordinator() -> Coordinator {
    Coordinator(date: $date)
  }

  func makeUIView(context: Context) -> PrimedDatePickerView {
    let view = PrimedDatePickerView()
    view.picker.tintColor = UIColor(Theme.accent)
    view.picker.date = date
    view.picker.addTarget(
      context.coordinator,
      action: #selector(Coordinator.changed(_:)),
      for: .valueChanged
    )
    return view
  }

  func updateUIView(_ view: PrimedDatePickerView, context: Context) {
    context.coordinator.date = $date
    if view.picker.date != date {
      view.picker.date = date
    }
    view.picker.tintColor = UIColor(Theme.accent)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: PrimedDatePickerView,
    context: Context
  ) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    guard width > 1 else {
      return uiView.bounds.size
    }
    return uiView.prime(width: width)
  }

  final class Coordinator: NSObject {
    var date: Binding<Date>

    init(date: Binding<Date>) {
      self.date = date
    }

    @objc func changed(_ picker: UIDatePicker) {
      date.wrappedValue = picker.date
    }
  }
}

private final class PrimedDatePickerView: UIView {
  static let compressedMinimumHeight: CGFloat = 324

  let picker: UIDatePicker = {
    let picker = UIDatePicker()
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .inline
    picker.calendar = .current
    picker.locale = .current
    return picker
  }()

  private var lockedHeight: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  @discardableResult
  func prime(width: CGFloat) -> CGSize {
    if picker.superview == nil {
      addSubview(picker)
    }
    let measured = twoPassHeight(width: width)
    let height: CGFloat
    if abs(measured - Self.compressedMinimumHeight) < 0.5 {
      height = max(measured, Self.reservedHeight(forWidth: width))
    } else {
      height = measured
    }
    lockedHeight = height
    applyFrames(width: width, height: height)
    return CGSize(width: width, height: height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard picker.superview != nil, lockedHeight > 1 else {
      return
    }
    applyFrames(width: bounds.width, height: lockedHeight)
  }

  private func twoPassHeight(width: CGFloat) -> CGFloat {
    let fitting = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
    bounds.size.width = width
    picker.frame.size.width = width
    picker.setNeedsLayout()
    picker.layoutIfNeeded()
    var height = picker.sizeThatFits(fitting).height
    picker.frame.size.height = max(height, 1)
    picker.setNeedsLayout()
    picker.layoutIfNeeded()
    height = max(height, picker.sizeThatFits(fitting).height)
    guard let calendar = Self.calendarView(in: picker) else {
      return height
    }
    calendar.setNeedsLayout()
    calendar.layoutIfNeeded()
    let first = calendar.sizeThatFits(fitting).height
    calendar.bounds.size.height = max(first, 1)
    calendar.setNeedsLayout()
    calendar.layoutIfNeeded()
    let second = calendar.sizeThatFits(fitting).height
    return max(height, first, second)
  }

  private func applyFrames(width: CGFloat, height: CGFloat) {
    picker.frame = CGRect(x: 0, y: 0, width: width, height: height)
    bounds.size = CGSize(width: width, height: height)
    if let calendar = Self.calendarView(in: picker) {
      calendar.bounds.size.height = height
    }
  }

  private static func reservedHeight(forWidth width: CGFloat) -> CGFloat {
    let cell = floor(width / 7)
    return 54 + 22 + (6 * cell)
  }

  private static func calendarView(in view: UIView) -> UIView? {
    if String(describing: type(of: view)).contains("UICalendarView") {
      return view
    }
    return view.subviews.lazy.compactMap { calendarView(in: $0) }.first
  }
}
