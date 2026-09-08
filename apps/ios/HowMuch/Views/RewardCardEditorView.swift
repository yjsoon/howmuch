import SwiftUI

enum RewardCardWriteError: LocalizedError, Equatable {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let text):
      return text
    }
  }
}

struct RewardFlagDraft: Identifiable, Equatable {
  var id: String
  var name: String
  var flagColor: RewardFlagColour
  var rewardValue: String
  var priority: String
  var active: Bool
  var excludeFromRewards: Bool
  var milesBlockSize: String
  var minimumSpend: String
  var maximumSpend: String
  var createdAt: String
  var updatedAt: String

  static func fresh(priority: String = "1", name: String = "", flagColor: RewardFlagColour = .red, rewardValue: String = "") -> RewardFlagDraft {
    let now = RewardCardDraft.nowISO
    return RewardFlagDraft(
      id: "subcat_\(UUID().uuidString)",
      name: name,
      flagColor: flagColor,
      rewardValue: rewardValue,
      priority: priority,
      active: true,
      excludeFromRewards: false,
      milesBlockSize: "",
      minimumSpend: "",
      maximumSpend: "",
      createdAt: now,
      updatedAt: now
    )
  }

  init(
    id: String,
    name: String,
    flagColor: RewardFlagColour,
    rewardValue: String,
    priority: String,
    active: Bool,
    excludeFromRewards: Bool,
    milesBlockSize: String,
    minimumSpend: String,
    maximumSpend: String,
    createdAt: String,
    updatedAt: String
  ) {
    self.id = id
    self.name = name
    self.flagColor = flagColor
    self.rewardValue = rewardValue
    self.priority = priority
    self.active = active
    self.excludeFromRewards = excludeFromRewards
    self.milesBlockSize = milesBlockSize
    self.minimumSpend = minimumSpend
    self.maximumSpend = maximumSpend
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(flag: CardSubcategory) {
    let now = RewardCardDraft.nowISO
    id = flag.id.isEmpty ? "subcat_\(UUID().uuidString)" : flag.id
    name = flag.name
    flagColor = flag.flagColor
    rewardValue = RewardCardDraft.numberText(flag.rewardValue)
    priority = RewardCardDraft.numberText(flag.priority)
    active = flag.active
    excludeFromRewards = flag.excludeFromRewards == true
    milesBlockSize = RewardCardDraft.numberText(flag.milesBlockSize)
    minimumSpend = RewardCardDraft.numberText(flag.minimumSpend)
    maximumSpend = RewardCardDraft.numberText(flag.maximumSpend)
    createdAt = flag.createdAt.isEmpty ? now : flag.createdAt
    updatedAt = flag.updatedAt.isEmpty ? now : flag.updatedAt
  }

  mutating func touch() {
    updatedAt = RewardCardDraft.nowISO
  }
}

struct RewardTierOverrideDraft: Identifiable, Equatable {
  var id: String
  var subcategoryId: String
  var rewardValue: String
  var maximumSpend: String

  init(id: String = UUID().uuidString, subcategoryId: String = "", rewardValue: String = "", maximumSpend: String = "") {
    self.id = id
    self.subcategoryId = subcategoryId
    self.rewardValue = rewardValue
    self.maximumSpend = maximumSpend
  }

  init(override: SpendingTierSubcategory) {
    id = UUID().uuidString
    subcategoryId = override.subcategoryId
    rewardValue = RewardCardDraft.numberText(override.rewardValue)
    maximumSpend = RewardCardDraft.numberText(override.maximumSpend)
  }
}

struct RewardTierDraft: Identifiable, Equatable {
  var id: String
  var spendThreshold: String
  var earningRate: String
  var maximumSpend: String
  var overrides: [RewardTierOverrideDraft]

  static func fresh() -> RewardTierDraft {
    RewardTierDraft(
      id: "tier_\(UUID().uuidString)",
      spendThreshold: "",
      earningRate: "",
      maximumSpend: "",
      overrides: []
    )
  }

  init(id: String, spendThreshold: String, earningRate: String, maximumSpend: String, overrides: [RewardTierOverrideDraft]) {
    self.id = id
    self.spendThreshold = spendThreshold
    self.earningRate = earningRate
    self.maximumSpend = maximumSpend
    self.overrides = overrides
  }

  init(tier: CardSpendingTier) {
    id = tier.id
    spendThreshold = RewardCardDraft.numberText(tier.spendThreshold)
    earningRate = RewardCardDraft.numberText(tier.earningRate)
    maximumSpend = RewardCardDraft.numberText(tier.maximumSpend)
    overrides = (tier.subcategories ?? []).map(RewardTierOverrideDraft.init)
  }
}

struct RewardCardDraft: Equatable {
  var id: String
  var name: String
  var issuer: String
  var type: RewardKind
  var ynabAccountId: String
  var featured: Bool
  var billingType: CardBillingType
  var billingDay: String
  var rewardMonthCount: String
  var rewardAnchorDate: String
  var rewardMonthlyMinimum: String
  var promoStart: String
  var promoEnd: String
  var promoDescription: String
  var earningRate: String
  var earningBlockSize: String
  var minimumSpend: String
  var maximumSpend: String
  var flags: [RewardFlagDraft]
  var tiers: [RewardTierDraft]

  static var nowISO: String {
    ISO8601DateFormatter().string(from: Date())
  }

  static func numberText(_ value: Double?) -> String {
    guard let value else {
      return ""
    }
    return String(value)
  }

  static func empty() -> RewardCardDraft {
    RewardCardDraft(
      id: "card_\(UUID().uuidString)",
      name: "",
      issuer: "",
      type: .cashback,
      ynabAccountId: "",
      featured: true,
      billingType: .calendar,
      billingDay: "",
      rewardMonthCount: "",
      rewardAnchorDate: "",
      rewardMonthlyMinimum: "",
      promoStart: "",
      promoEnd: "",
      promoDescription: "",
      earningRate: "",
      earningBlockSize: "",
      minimumSpend: "",
      maximumSpend: "",
      flags: [],
      tiers: []
    )
  }

  init(
    id: String,
    name: String,
    issuer: String,
    type: RewardKind,
    ynabAccountId: String,
    featured: Bool,
    billingType: CardBillingType,
    billingDay: String,
    rewardMonthCount: String,
    rewardAnchorDate: String,
    rewardMonthlyMinimum: String,
    promoStart: String,
    promoEnd: String,
    promoDescription: String,
    earningRate: String,
    earningBlockSize: String,
    minimumSpend: String,
    maximumSpend: String,
    flags: [RewardFlagDraft],
    tiers: [RewardTierDraft]
  ) {
    self.id = id
    self.name = name
    self.issuer = issuer
    self.type = type
    self.ynabAccountId = ynabAccountId
    self.featured = featured
    self.billingType = billingType
    self.billingDay = billingDay
    self.rewardMonthCount = rewardMonthCount
    self.rewardAnchorDate = rewardAnchorDate
    self.rewardMonthlyMinimum = rewardMonthlyMinimum
    self.promoStart = promoStart
    self.promoEnd = promoEnd
    self.promoDescription = promoDescription
    self.earningRate = earningRate
    self.earningBlockSize = earningBlockSize
    self.minimumSpend = minimumSpend
    self.maximumSpend = maximumSpend
    self.flags = flags
    self.tiers = tiers
  }

  init(card: CreditCard) {
    id = card.id
    name = card.name
    issuer = card.issuer
    type = card.type
    ynabAccountId = card.ynabAccountId
    featured = card.featured
    billingType = card.billingCycle?.type ?? .calendar
    billingDay = Self.numberText(card.billingCycle?.dayOfMonth)
    rewardMonthCount = Self.numberText(card.rewardPeriod?.monthCount)
    rewardAnchorDate = card.rewardPeriod?.anchorDate ?? ""
    rewardMonthlyMinimum = Self.numberText(card.rewardPeriod?.monthlyMinimumSpend)
    promoStart = card.promotionalPeriod?.startDate ?? ""
    promoEnd = card.promotionalPeriod?.endDate ?? ""
    promoDescription = card.promotionalPeriod?.description ?? ""
    earningRate = Self.numberText(card.earningRate)
    earningBlockSize = Self.numberText(card.earningBlockSize)
    minimumSpend = Self.numberText(card.minimumSpend)
    maximumSpend = Self.numberText(card.maximumSpend)
    flags = (card.subcategories ?? []).map(RewardFlagDraft.init)
    tiers = (card.spendingTiers ?? []).map(RewardTierDraft.init)
  }

  mutating func addFlag(_ flag: RewardFlagDraft? = nil) {
    flags.append(flag ?? RewardFlagDraft.fresh(priority: String(flags.count + 1)))
  }

  mutating func addImportedFlag(name: String, flagColor: RewardFlagColour, rewardValue: String) throws {
    let rate = try Self.requiredFinite(rewardValue, label: "Category flag rate")
    addFlag(
      RewardFlagDraft.fresh(
        priority: String(flags.count + 1),
        name: name,
        flagColor: flagColor,
        rewardValue: String(rate)
      )
    )
  }

  mutating func addTier() {
    tiers.append(.fresh())
  }

  func write() throws -> CreditCard {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedName.isEmpty {
      throw RewardCardWriteError.message("Enter a card name.")
    }
    if ynabAccountId.isEmpty {
      throw RewardCardWriteError.message("Choose a HowMuch account.")
    }

    var card = CreditCard(
      id: id,
      name: trimmedName,
      issuer: issuer.trimmingCharacters(in: .whitespacesAndNewlines),
      type: type,
      ynabAccountId: ynabAccountId,
      featured: featured
    )

    let billingDay = try Self.optionalFinite(self.billingDay, label: "Billing day of month")
    card.billingCycle = CardBillingCycle(type: billingType, dayOfMonth: billingDay)

    let rewardTouched = !rewardMonthCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !rewardAnchorDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !rewardMonthlyMinimum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if rewardTouched {
      let monthCount = try Self.requiredFinite(rewardMonthCount, label: "Reward period months")
      if rewardAnchorDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw RewardCardWriteError.message("Reward period needs an anchor date.")
      }
      let monthlyMinimum = try Self.requiredFinite(rewardMonthlyMinimum, label: "Monthly minimum spend")
      card.rewardPeriod = CardRewardPeriod(
        monthCount: monthCount,
        anchorDate: rewardAnchorDate,
        monthlyMinimumSpend: monthlyMinimum
      )
    }

    let promoTouched = !promoStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !promoEnd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !promoDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if promoTouched {
      if promoEnd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw RewardCardWriteError.message("Promotional period needs an end date.")
      }
      var promo = CardPromotionalPeriod(startDate: nil, endDate: promoEnd, description: nil)
      if !promoStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        promo.startDate = promoStart
      }
      let description = promoDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      if !description.isEmpty {
        promo.description = description
      }
      card.promotionalPeriod = promo
    }

    card.earningRate = try Self.optionalFinite(earningRate, label: "Earning rate")
    card.earningBlockSize = try Self.optionalFinite(earningBlockSize, label: "Block size")
    card.minimumSpend = try Self.optionalFinite(minimumSpend, label: "Minimum spend")
    card.maximumSpend = try Self.optionalFinite(maximumSpend, label: "Maximum spend")

    var writtenFlags: [CardSubcategory] = []
    for (index, flag) in flags.enumerated() {
      if flag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw RewardCardWriteError.message("Flag \(index + 1) needs a name.")
      }
      let rewardValue = try Self.requiredFinite(flag.rewardValue, label: "Flag \(index + 1) reward value")
      let priority = try Self.requiredFinite(flag.priority, label: "Flag \(index + 1) priority")
      var written = CardSubcategory(
        id: flag.id,
        name: flag.name.trimmingCharacters(in: .whitespacesAndNewlines),
        flagColor: flag.flagColor,
        rewardValue: rewardValue,
        milesBlockSize: nil,
        minimumSpend: nil,
        maximumSpend: nil,
        priority: priority,
        active: flag.active,
        excludeFromRewards: nil,
        createdAt: flag.createdAt,
        updatedAt: flag.updatedAt
      )
      written.milesBlockSize = try Self.optionalFinite(flag.milesBlockSize, label: "Flag \(index + 1) miles block")
      written.minimumSpend = try Self.optionalFinite(flag.minimumSpend, label: "Flag \(index + 1) minimum spend")
      written.maximumSpend = try Self.optionalFinite(flag.maximumSpend, label: "Flag \(index + 1) maximum spend")
      if flag.excludeFromRewards {
        written.excludeFromRewards = true
      }
      writtenFlags.append(written)
    }
    card.subcategoriesEnabled = !writtenFlags.isEmpty
    card.subcategories = writtenFlags

    var writtenTiers: [CardSpendingTier] = []
    for (index, tier) in tiers.enumerated() {
      let spendThreshold = try Self.requiredFinite(tier.spendThreshold, label: "Spending tier \(index + 1) threshold")
      var written = CardSpendingTier(
        id: tier.id,
        spendThreshold: spendThreshold,
        earningRate: nil,
        maximumSpend: nil,
        subcategories: nil
      )
      written.earningRate = try Self.optionalFinite(tier.earningRate, label: "Spending tier \(index + 1) earning rate")
      written.maximumSpend = try Self.optionalFinite(tier.maximumSpend, label: "Spending tier \(index + 1) maximum spend")
      if !tier.overrides.isEmpty {
        var overrides: [SpendingTierSubcategory] = []
        for (overrideIndex, override) in tier.overrides.enumerated() {
          if override.subcategoryId.isEmpty {
            throw RewardCardWriteError.message("Spending tier \(index + 1) override \(overrideIndex + 1) needs a flag.")
          }
          let overrideRate = try Self.requiredFinite(
            override.rewardValue,
            label: "Spending tier \(index + 1) override \(overrideIndex + 1) rate"
          )
          var mapped = SpendingTierSubcategory(
            subcategoryId: override.subcategoryId,
            rewardValue: overrideRate,
            maximumSpend: nil
          )
          mapped.maximumSpend = try Self.optionalFinite(
            override.maximumSpend,
            label: "Spending tier \(index + 1) override \(overrideIndex + 1) maximum"
          )
          overrides.append(mapped)
        }
        written.subcategories = overrides
      }
      writtenTiers.append(written)
    }
    card.spendingTiers = writtenTiers
    return card
  }

  private static func optionalFinite(_ text: String, label: String) throws -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return nil
    }
    guard let value = Double(trimmed), value.isFinite else {
      throw RewardCardWriteError.message("\(label) must be a number.")
    }
    return value
  }

  private static func requiredFinite(_ text: String, label: String) throws -> Double {
    guard let value = try optionalFinite(text, label: label) else {
      throw RewardCardWriteError.message("\(label) is required.")
    }
    return value
  }
}

struct RewardCardEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let cardID: String?

  @State private var draft = RewardCardDraft.empty()
  @State private var loadPhase: LoadPhase = .idle
  @State private var errorMessage: String?
  @State private var isSaving = false
  @State private var isDeleting = false
  @State private var isConfirmingDelete = false
  @State private var importCategoryId = ""
  @State private var importFlagColor: RewardFlagColour = .red
  @State private var importRate = ""
  @State private var ledger: [Transaction] = []
  @State private var ledgerPhase: LoadPhase = .idle
  @State private var flagOverrides: [String: String?] = [:]
  @State private var pendingFlagID: String?

  private var isEditing: Bool { cardID != nil }

  var body: some View {
    NavigationStack {
      Group {
        if cardID != nil, loadPhase == .loading, draft.ynabAccountId.isEmpty, draft.name.isEmpty {
          ProgressView("Loading card…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cardID != nil, case .failed(let message) = loadPhase, draft.name.isEmpty {
          ContentUnavailableView {
            Label("Card not found", systemImage: "creditcard")
          } description: {
            Text(message)
          }
        } else {
          editorForm
        }
      }
      .background(Theme.canvas)
      .navigationTitle(isEditing ? "Edit card" : "Add card")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
          }
          .disabled(isSaving || isDeleting)
          .accessibilityLabel("Cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
              .accessibilityLabel("Saving")
          } else {
            Button {
              Task { await save() }
            } label: {
              Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            .disabled(isDeleting)
            .accessibilityLabel("Save")
          }
        }
      }
      .binaryConfirm(
        "Delete this reward card?",
        isPresented: $isConfirmingDelete,
        confirm: .destructive("Delete card"),
        message: {
          Text("Ledger transactions stay. The card rules are removed.")
        }
      ) {
        Task { await remove() }
      }
      .interactiveDismissDisabled(isSaving || isDeleting)
      .task(id: cardID ?? "new") {
        await loadCard()
      }
      .task(id: draft.ynabAccountId) {
        await loadLedger()
      }
    }
  }

  private var editorForm: some View {
    Form {
      Section {
        TextField("Name", text: $draft.name)
        TextField("Issuer", text: $draft.issuer)
        Picker("Type", selection: $draft.type) {
          Text("Cashback").tag(RewardKind.cashback)
          Text("Miles").tag(RewardKind.miles)
        }
        Picker("HowMuch account", selection: $draft.ynabAccountId) {
          Text("Choose account").tag("")
          ForEach(accountChoices) { account in
            Text(account.closed ? "\(account.name) (closed)" : account.name).tag(account.id)
          }
        }
        Toggle("Featured", isOn: $draft.featured)
      } header: {
        Text(isEditing ? "Card details" : "New card")
      } footer: {
        Text("Rules apply to the mapped HowMuch account.")
      }

      Section("Billing cycle") {
        Picker("Billing cycle", selection: $draft.billingType) {
          ForEach(CardBillingType.allCases) { type in
            Text(type.title).tag(type)
          }
        }
        TextField("Day of month", text: $draft.billingDay)
          .keyboardType(.numberPad)
      }

      Section {
        TextField("Reward period months", text: $draft.rewardMonthCount)
          .keyboardType(.numberPad)
        TextField("Anchor date", text: $draft.rewardAnchorDate)
        TextField("Monthly minimum spend", text: $draft.rewardMonthlyMinimum)
          .keyboardType(.decimalPad)
      } header: {
        Text("Reward period")
      } footer: {
        Text("Leave the reward period blank if this card has no qualifying window.")
      }

      Section("Promotional period") {
        TextField("Promotional start", text: $draft.promoStart)
        TextField("Promotional end", text: $draft.promoEnd)
        TextField("Promotional description", text: $draft.promoDescription)
      }

      Section("Rates") {
        TextField("Earning rate", text: $draft.earningRate)
          .keyboardType(.decimalPad)
        TextField("Block size", text: $draft.earningBlockSize)
          .keyboardType(.decimalPad)
        TextField("Minimum spend", text: $draft.minimumSpend)
          .keyboardType(.decimalPad)
        TextField("Maximum spend", text: $draft.maximumSpend)
          .keyboardType(.decimalPad)
      }

      Section {
        Picker("Import category", selection: $importCategoryId) {
          Text("Choose category").tag("")
          ForEach(importableCategories, id: \.id) { category in
            Text(category.name).tag(category.id)
          }
        }
        .accessibilityLabel("Import category")
        Picker("Flag colour", selection: $importFlagColor) {
          ForEach(RewardFlagColour.allCases) { colour in
            Text(colour.title).tag(colour)
          }
        }
        TextField("Rate", text: $importRate)
          .keyboardType(.decimalPad)
        Button("Add flag from category") {
          addImportedFlag()
        }
        ForEach($draft.flags) { $flag in
          flagEditor($flag)
        }
        Button("Add flag") {
          draft.addFlag()
        }
      } header: {
        Text("Flag subcategories")
      } footer: {
        Text("Unflagged is a flag colour HowMuch can score. The ledger picker still uses None for no colour.")
      }

      Section("Spending tiers") {
        ForEach($draft.tiers) { $tier in
          tierEditor($tier)
        }
        Button("Add spending tier") {
          draft.addTier()
        }
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
          Button("Delete card", role: .destructive) {
            isConfirmingDelete = true
          }
          .disabled(isSaving || isDeleting)
          .accessibilityLabel("Delete card")
        }
      }

      if !draft.ynabAccountId.isEmpty {
        ledgerSection
      }
    }
    .scrollContentBackground(.hidden)
  }

  private var ledgerSection: some View {
    Section {
      if ledgerPhase == .loading && ledger.isEmpty {
        HStack {
          Text("Loading transactions…")
          Spacer()
          ProgressView()
        }
      } else if let message = ledgerPhase.errorMessage, ledger.isEmpty {
        Text(message)
          .foregroundStyle(Theme.outflow)
      } else if ledger.isEmpty {
        Text("No transactions on this account.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(ledger) { transaction in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(transaction.date)
              Spacer()
              Text(MoneyCodec.signedDisplayString(for: transaction.amount, currencyFormat: model.currencyFormat))
                .monospacedDigit()
                .foregroundStyle(Theme.amountColour(transaction.amount))
            }
            Text(transaction.payeeName ?? "No payee")
              .foregroundStyle(.secondary)
            Picker("Flag", selection: flagColourBinding(for: transaction)) {
              ForEach(FlagColour.allCases) { colour in
                Text(colour.title).tag(colour)
              }
            }
            .disabled(pendingFlagID == transaction.id)
            .accessibilityLabel("Flag")
          }
        }
      }
    } header: {
      Text("Account ledger")
    } footer: {
      Text("Newest first")
    }
  }

  @ViewBuilder
  private func flagEditor(_ flag: Binding<RewardFlagDraft>) -> some View {
    let index = draft.flags.firstIndex(where: { $0.id == flag.wrappedValue.id }) ?? 0
    VStack(alignment: .leading, spacing: 8) {
      TextField("Name", text: Binding(
        get: { flag.wrappedValue.name },
        set: { flag.wrappedValue.name = $0; flag.wrappedValue.touch() }
      ))
      .accessibilityLabel("Flag \(index + 1) name")
      Picker("Flag colour", selection: Binding(
        get: { flag.wrappedValue.flagColor },
        set: { flag.wrappedValue.flagColor = $0; flag.wrappedValue.touch() }
      )) {
        ForEach(RewardFlagColour.allCases) { colour in
          Text(colour.title).tag(colour)
        }
      }
      .accessibilityLabel("Flag \(index + 1) colour")
      TextField("Reward value", text: Binding(
        get: { flag.wrappedValue.rewardValue },
        set: { flag.wrappedValue.rewardValue = $0; flag.wrappedValue.touch() }
      ))
      .keyboardType(.decimalPad)
      .accessibilityLabel("Flag \(index + 1) reward value")
      TextField("Priority", text: Binding(
        get: { flag.wrappedValue.priority },
        set: { flag.wrappedValue.priority = $0; flag.wrappedValue.touch() }
      ))
      .keyboardType(.numberPad)
      .accessibilityLabel("Flag \(index + 1) priority")
      TextField("Minimum spend", text: Binding(
        get: { flag.wrappedValue.minimumSpend },
        set: { flag.wrappedValue.minimumSpend = $0; flag.wrappedValue.touch() }
      ))
      .keyboardType(.decimalPad)
      TextField("Maximum spend", text: Binding(
        get: { flag.wrappedValue.maximumSpend },
        set: { flag.wrappedValue.maximumSpend = $0; flag.wrappedValue.touch() }
      ))
      .keyboardType(.decimalPad)
      TextField("Miles block", text: Binding(
        get: { flag.wrappedValue.milesBlockSize },
        set: { flag.wrappedValue.milesBlockSize = $0; flag.wrappedValue.touch() }
      ))
      .keyboardType(.decimalPad)
      Toggle("Active", isOn: Binding(
        get: { flag.wrappedValue.active },
        set: { flag.wrappedValue.active = $0; flag.wrappedValue.touch() }
      ))
      Toggle("Exclude from rewards", isOn: Binding(
        get: { flag.wrappedValue.excludeFromRewards },
        set: { flag.wrappedValue.excludeFromRewards = $0; flag.wrappedValue.touch() }
      ))
      Button("Remove", role: .destructive) {
        draft.flags.removeAll { $0.id == flag.wrappedValue.id }
      }
    }
  }

  @ViewBuilder
  private func tierEditor(_ tier: Binding<RewardTierDraft>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Spend threshold", text: tier.spendThreshold)
        .keyboardType(.decimalPad)
      TextField("Earning rate", text: tier.earningRate)
        .keyboardType(.decimalPad)
      TextField("Maximum spend", text: tier.maximumSpend)
        .keyboardType(.decimalPad)
      ForEach(tier.overrides) { $override in
        Picker("Flag override", selection: $override.subcategoryId) {
          Text("Choose flag").tag("")
          ForEach(draft.flags) { flag in
            Text(flag.name.isEmpty ? flag.flagColor.title : flag.name).tag(flag.id)
          }
        }
        TextField("Override rate", text: $override.rewardValue)
          .keyboardType(.decimalPad)
        TextField("Override maximum", text: $override.maximumSpend)
          .keyboardType(.decimalPad)
        Button("Remove override", role: .destructive) {
          tier.wrappedValue.overrides.removeAll { $0.id == override.id }
        }
      }
      Button("Add flag override") {
        tier.wrappedValue.overrides.append(
          RewardTierOverrideDraft(subcategoryId: draft.flags.first?.id ?? "")
        )
      }
      Button("Remove tier", role: .destructive) {
        draft.tiers.removeAll { $0.id == tier.wrappedValue.id }
      }
    }
  }

  private var accountChoices: [Account] {
    model.accounts.sorted { left, right in
      if left.closed != right.closed {
        return !left.closed && right.closed
      }
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  private var importableCategories: [Category] {
    model.categoryGroups
      .filter { !$0.deleted }
      .flatMap { group in
        group.categories.filter { !$0.deleted }
      }
  }

  private func flagColourBinding(for transaction: Transaction) -> Binding<FlagColour> {
    Binding(
      get: {
        let raw = flagOverrides[transaction.id] ?? transaction.flagColor
        return FlagColour(rawValue: raw ?? "") ?? .none
      },
      set: { colour in
        Task { await setFlag(transaction, colour == .none ? nil : colour.rawValue) }
      }
    )
  }

  private func addImportedFlag() {
    let name = model.categoryName(forID: importCategoryId) ?? ""
    guard !importCategoryId.isEmpty, !name.isEmpty else {
      errorMessage = "Choose a category to add as a flag."
      return
    }
    do {
      try draft.addImportedFlag(name: name, flagColor: importFlagColor, rewardValue: importRate)
      errorMessage = nil
      importCategoryId = ""
      importRate = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func loadCard() async {
    guard let cardID else {
      draft = .empty()
      loadPhase = .loaded
      return
    }
    loadPhase = .loading
    do {
      let snapshot = try await model.apiClient.fetchRewardsTrackerSnapshot(planID: model.settings.planID)
      guard let card = snapshot.cards.first(where: { $0.id == cardID }) else {
        loadPhase = .failed("This card is not stored on this plan.")
        return
      }
      draft = RewardCardDraft(card: card)
      loadPhase = .loaded
    } catch {
      loadPhase = .failed(error.localizedDescription)
    }
  }

  private func loadLedger() async {
    let accountID = draft.ynabAccountId
    guard !accountID.isEmpty else {
      ledger = []
      ledgerPhase = .loaded
      return
    }
    ledgerPhase = .loading
    do {
      let page = try await model.apiClient.fetchTransactions(
        planID: model.settings.planID,
        accountID: accountID
      )
      guard accountID == draft.ynabAccountId else {
        return
      }
      ledger = page.transactions
      flagOverrides = [:]
      ledgerPhase = .loaded
    } catch {
      guard accountID == draft.ynabAccountId else {
        return
      }
      ledgerPhase = .failed(error.localizedDescription)
    }
  }

  private func setFlag(_ transaction: Transaction, _ value: String?) async {
    pendingFlagID = transaction.id
    errorMessage = nil
    do {
      _ = try await model.apiClient.updateTransaction(
        planID: model.settings.planID,
        transactionID: transaction.id,
        request: transaction.rewardFlagWriteRequest(flagColor: value)
      )
      flagOverrides[transaction.id] = value
    } catch {
      errorMessage = error.localizedDescription
    }
    pendingFlagID = nil
  }

  private func save() async {
    let written: CreditCard
    do {
      written = try draft.write()
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    isSaving = true
    errorMessage = nil
    do {
      if let cardID {
        _ = try await model.apiClient.updateRewardCard(
          planID: model.settings.planID,
          cardID: cardID,
          card: written
        )
      } else {
        _ = try await model.apiClient.createRewardCard(
          planID: model.settings.planID,
          card: written
        )
      }
      closeAfterWrite()
    } catch {
      errorMessage = error.localizedDescription
      isSaving = false
    }
  }

  private func closeAfterWrite() {
    model.noteRewardsBoardChanged()
    var transaction = SwiftUI.Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      dismiss()
    }
  }

  private func remove() async {
    guard let cardID else {
      return
    }
    isDeleting = true
    errorMessage = nil
    do {
      _ = try await model.apiClient.deleteRewardCard(planID: model.settings.planID, cardID: cardID)
      closeAfterWrite()
    } catch {
      errorMessage = error.localizedDescription
      isDeleting = false
    }
  }
}

private extension Transaction {
  func rewardFlagWriteRequest(flagColor: String?) -> TransactionWriteRequest {
    TransactionWriteRequest(
      accountID: accountID,
      date: date,
      amount: amount,
      payeeID: payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      memo: memo,
      cleared: nil,
      approved: approved,
      flagColor: flagColor,
      subtransactions: subtransactions.filter { !$0.deleted }.map {
        TransactionSubtransactionWriteRequest(
          id: $0.id,
          amount: $0.amount,
          payeeID: $0.payeeID,
          payeeName: $0.payeeName,
          categoryID: $0.categoryID,
          memo: $0.memo,
          transferAccountID: $0.transferAccountID,
          transferTransactionID: $0.transferTransactionID
        )
      },
      importID: importID
    )
  }
}
