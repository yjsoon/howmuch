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

enum RewardCardAccounts {
  static func choices(accounts: [Account], takenIDs: Set<String>, keepingID: String?) -> [Account] {
    accounts
      .filter { account in
        if account.deleted { return false }
        if let keepingID, account.id == keepingID { return true }
        if takenIDs.contains(account.id) { return false }
        return account.onBudget && !account.closed
      }
      .sorted { left, right in
        if left.closed != right.closed {
          return !left.closed && right.closed
        }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
  }

  static func syncedName(name: String, previousAccountName: String?, nextAccountName: String?) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let wasSynced = trimmed.isEmpty || trimmed == (previousAccountName ?? "")
    if !wasSynced { return name }
    return nextAccountName ?? ""
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
    id = flag.id
    name = flag.name
    flagColor = flag.flagColor
    rewardValue = RewardCardDraft.numberText(flag.rewardValue)
    priority = RewardCardDraft.numberText(flag.priority)
    active = flag.active
    excludeFromRewards = flag.excludeFromRewards == true
    milesBlockSize = RewardCardDraft.numberText(flag.milesBlockSize)
    minimumSpend = RewardCardDraft.numberText(flag.minimumSpend)
    maximumSpend = RewardCardDraft.numberText(flag.maximumSpend)
    createdAt = flag.createdAt
    updatedAt = flag.updatedAt
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
    id = override.subcategoryId
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
  var flagNames: [RewardFlagColour: String]
  var tiers: [RewardTierDraft]
  var subcategoriesEnabled = false
  private var originalCard: CreditCard?

  /// Read on every edit keystroke, so the formatter is built once.
  static var nowISO: String {
    isoFormatter.string(from: Date())
  }

  private static let isoFormatter = ISO8601DateFormatter()

  static func numberText(_ value: Double?) -> String {
    guard let value else {
      return ""
    }
    let text = String(value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
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
      flagNames: [:],
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
    flagNames: [RewardFlagColour: String],
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
    self.flagNames = flagNames
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
    flagNames = Self.colourNames(from: card)
    tiers = (card.spendingTiers ?? []).map(RewardTierDraft.init)
    subcategoriesEnabled = card.subcategoriesEnabled ?? false
    originalCard = card
  }

  static func colourNames(from card: CreditCard) -> [RewardFlagColour: String] {
    var names: [RewardFlagColour: String] = [:]
    for flag in card.subcategories ?? [] {
      let trimmed = flag.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        names[flag.flagColor] = trimmed
      }
    }
    for (raw, name) in card.flagNames ?? [:] {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let colour = RewardFlagColour(rawValue: raw) else { continue }
      names[colour] = trimmed
    }
    return names
  }

  mutating func addFlag(_ flag: RewardFlagDraft? = nil) {
    flags.append(flag ?? RewardFlagDraft.fresh(priority: String(flags.count + 1)))
  }

  mutating func addImportedFlag(name: String, flagColor: RewardFlagColour, rewardValue: String) throws {
    let rate = try Self.requiredFinite(rewardValue, label: "Category flag rate")
    if (flagNames[flagColor] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      flagNames[flagColor] = name
    }
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

  mutating func selectAccount(id: String, from accounts: [Account]) {
    let previous = accounts.first { $0.id == ynabAccountId }
    let next = accounts.first { $0.id == id }
    name = RewardCardAccounts.syncedName(
      name: name,
      previousAccountName: previous?.name,
      nextAccountName: next?.name
    )
    ynabAccountId = id
  }

  func write() throws -> CreditCard {
    if ynabAccountId.isEmpty {
      throw RewardCardWriteError.message("Choose a Halation account.")
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedName.isEmpty {
      throw RewardCardWriteError.message("Enter a rewards label in Display & saved details.")
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
    if let billingDay {
      guard billingDay.rounded() == billingDay, (1...31).contains(billingDay) else {
        throw RewardCardWriteError.message("Billing day must be an integer from 1 to 31.")
      }
    } else if billingType == .billing {
      throw RewardCardWriteError.message("Billing cycle needs a day of month.")
    }
    card.billingCycle = CardBillingCycle(type: billingType, dayOfMonth: billingDay)

    let rewardTouched = !rewardMonthCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !rewardAnchorDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !rewardMonthlyMinimum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if rewardTouched {
      let monthCount = try Self.requiredFinite(rewardMonthCount, label: "Reward period months")
      guard monthCount.rounded() == monthCount, (2...24).contains(monthCount) else {
        throw RewardCardWriteError.message("Reward period must be an integer from 2 to 24 months.")
      }
      try Self.validateDate(rewardAnchorDate, label: "Anchor date")
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
      try Self.validateDate(promoEnd, label: "Promotional end")
      if !promoStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try Self.validateDate(promoStart, label: "Promotional start")
        guard promoStart <= promoEnd else {
          throw RewardCardWriteError.message("Promotional start must be on or before its end.")
        }
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
      let colourName = (flagNames[flag.flagColor] ?? flag.name).trimmingCharacters(in: .whitespacesAndNewlines)
      if colourName.isEmpty {
        throw RewardCardWriteError.message("Flag \(index + 1): name the \(flag.flagColor.ledgerColour.title) colour.")
      }
      let rewardValue = try Self.requiredFinite(flag.rewardValue, label: "Flag \(index + 1) reward value")
      let priority = try Self.requiredFinite(flag.priority, label: "Flag \(index + 1) priority", nonnegative: false)
      var written = CardSubcategory(
        id: flag.id,
        name: colourName,
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
      } else if originalCard?.subcategories?.first(where: { $0.id == flag.id })?.excludeFromRewards != nil {
        written.excludeFromRewards = false
      }
      if let originalCard,
        let original = originalCard.subcategories?.first(where: { $0.id == flag.id }),
        flag.name == original.name,
        flagNames[flag.flagColor] == Self.colourNames(from: originalCard)[flag.flagColor] {
        written.name = original.name
      }
      writtenFlags.append(written)
    }
    card.subcategoriesEnabled = subcategoriesEnabled
    card.subcategories = writtenFlags
    let encodedNames = Dictionary(uniqueKeysWithValues: flagNames.compactMap { colour, name -> (String, String)? in
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : (colour.rawValue, trimmed)
    })
    if !encodedNames.isEmpty {
      card.flagNames = encodedNames
    }

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
    // Preserve absent optional configuration and independent labels on unrelated edits.
    if let originalCard {
      let original = Self(card: originalCard)
      if name == original.name { card.name = originalCard.name }
      if issuer == original.issuer { card.issuer = originalCard.issuer }
      if billingType == original.billingType, self.billingDay == original.billingDay {
        card.billingCycle = originalCard.billingCycle
      }
      if promoStart == original.promoStart, promoEnd == original.promoEnd,
        promoDescription == original.promoDescription {
        card.promotionalPeriod = originalCard.promotionalPeriod
      }
      if flags == original.flags { card.subcategories = originalCard.subcategories }
      if tiers == original.tiers { card.spendingTiers = originalCard.spendingTiers }
      if flagNames == original.flagNames { card.flagNames = originalCard.flagNames }
      if subcategoriesEnabled == original.subcategoriesEnabled {
        card.subcategoriesEnabled = originalCard.subcategoriesEnabled
      }
    }
    return card
  }

  func ledgerTitle(for colour: FlagColour) -> String {
    let named = flagNames[RewardFlagColour(ledgerColour: colour)]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return named.isEmpty ? colour.title : named
  }

  func displayName(for flag: RewardFlagDraft) -> String {
    let named = flagNames[flag.flagColor]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !named.isEmpty {
      return named
    }
    let fallback = flag.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return fallback.isEmpty ? flag.flagColor.title : fallback
  }

  private static func optionalFinite(_ text: String, label: String, nonnegative: Bool = true) throws -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return nil
    }
    guard let value = Double(trimmed), value.isFinite else {
      throw RewardCardWriteError.message("\(label) must be a number.")
    }
    if nonnegative && value < 0 {
      throw RewardCardWriteError.message("\(label) must be nonnegative.")
    }
    return value
  }

  private static func validateDate(_ text: String, label: String) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
      throw RewardCardWriteError.message("\(label) must be a real date in YYYY-MM-DD format.")
    }
  }

  private static func requiredFinite(_ text: String, label: String, nonnegative: Bool = true) throws -> Double {
    guard let value = try optionalFinite(text, label: label, nonnegative: nonnegative) else {
      throw RewardCardWriteError.message("\(label) is required.")
    }
    return value
  }
}

struct RewardCardEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
  @State private var takenAccountIDs: Set<String> = []
  @State private var originalDraft: RewardCardDraft?
  @State private var isConfirmingDiscard = false
  @State private var path: [Destination] = []
  @State private var errorRevision = 0

  private enum Destination: Hashable {
    case rule(Rule)
    case flag(String)
    case tier(String)
  }

  private enum Rule: String, CaseIterable, Identifiable {
    case flags = "Flag-based rewards"
    case tiers = "Spending tiers"
    case qualification = "Multi-month qualification"
    case promotion = "Promotion"
    case rounding = "Spend rounding"
    case display = "Display & saved details"
    var id: Self { self }
  }

  private var isEditing: Bool { cardID != nil }
  private var isDirty: Bool { originalDraft.map { $0 != draft } ?? false }
  private var currency: String {
    model.currencyFormat?.isoCode ?? model.currencyFormat?.currencySymbol ?? "$"
  }
  private var rateUnit: String { draft.type == .cashback ? "%" : "miles / \(currency)" }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if originalDraft != nil {
          editorForm
        } else if case .failed(let message) = loadPhase {
          ContentUnavailableView {
            Label("Could not load rewards", systemImage: "creditcard")
          } description: {
            Text(message)
          } actions: {
            Button("Retry loading") { Task { await loadCard() } }
          }
        } else {
          ProgressView(isEditing ? "Loading card…" : "Loading accounts…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Theme.canvas)
      .navigationTitle(isEditing ? "Edit Rewards" : "Set Up Rewards")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Destination.self) { destination in
        switch destination {
        case .rule(let rule): ruleForm(rule)
        case .flag(let id):
          if let flag = flagBinding(id) {
            draftForm { flagEditor(flag) }.navigationTitle(
              draft.displayName(for: flag.wrappedValue))
          }
        case .tier(let id):
          if let tier = tierBinding(id) {
            draftForm { tierEditor(tier) }.navigationTitle("Spending tier")
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if isDirty { isConfirmingDiscard = true } else { dismiss() }
          }
          .disabled(isSaving || isDeleting)
          .accessibilityLabel("Cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
              .accessibilityLabel("Saving")
          } else {
            Button("Save") {
              Task { await save() }
            }
            .disabled(isDeleting || originalDraft == nil)
            .accessibilityLabel("Save")
          }
        }
      }
      .binaryConfirm(
        "Remove Rewards?",
        isPresented: $isConfirmingDelete,
        confirm: .destructive("Remove Rewards"),
        message: {
          Text("Only the rewards settings are removed. Your account and transactions remain.")
        }
      ) {
        Task { await remove() }
      }
      .binaryConfirm(
        "Discard reward changes?", isPresented: $isConfirmingDiscard,
        confirm: .destructive("Discard changes"),
        message: {
          Text("Discard the unsaved changes in this draft?")
        }
      ) { dismiss() }
      .interactiveDismissDisabled(isDirty || isSaving || isDeleting)
      .task(id: cardID ?? "new") {
        await loadCard()
      }
    }
  }

  private var editorForm: some View {
    draftForm {
      Section {
        if isEditing {
          Label {
            VStack(alignment: .leading, spacing: 4) {
              Text(model.accounts.first { $0.id == draft.ynabAccountId }?.name ?? draft.name)
                .font(.headline)
              Text("Rewards settings · linked account").font(.caption).foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "creditcard").foregroundStyle(Theme.accent)
          }
        } else {
          if accountChoices.isEmpty {
            Text(
              "No available accounts. Add an open on-budget account, or edit an account already tracked for rewards."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          Picker("Halation account", selection: $draft.ynabAccountId) {
            Text("Choose a Halation account").tag("")
            ForEach(accountChoices) { account in
              Text(account.closed ? "\(account.name) (closed)" : account.name).tag(account.id)
            }
          }
          .onChange(of: draft.ynabAccountId) { oldValue, newValue in
            guard oldValue != newValue else { return }
            let previous = model.accounts.first { $0.id == oldValue }
            let next = model.accounts.first { $0.id == newValue }
            draft.name = RewardCardAccounts.syncedName(
              name: draft.name,
              previousAccountName: previous?.name,
              nextAccountName: next?.name
            )
          }
        }
      }
      Section {
        Picker("Reward type", selection: $draft.type) {
          Text("Cashback").tag(RewardKind.cashback)
          Text("Miles").tag(RewardKind.miles)
        }
        numberField(
          draft.type == .cashback ? "Cashback rate" : "Earning rate", text: $draft.earningRate,
          unit: rateUnit)
      } header: {
        Text("Earning")
      } footer: {
        if !draft.tiers.isEmpty
          || (draft.subcategoriesEnabled && draft.flags.contains(where: \.active))
        {
          Text("Additional rules may override this base rate.")
        }
      }

      Section {
        Picker("Cycle", selection: $draft.billingType) {
          ForEach(CardBillingType.allCases) { type in
            Text(type.title).tag(type)
          }
        }
        if draft.billingType == .billing {
          Picker("Cycle starts on", selection: $draft.billingDay) {
            Text("Choose day").tag("")
            ForEach(1...31, id: \.self) { day in Text("Day \(day)").tag(String(day)) }
          }
        }
        if let preview = RewardDraftPeriod.make(draft) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Prospective period: \(dateLabel(preview.start)) – \(dateLabel(preview.end))")
              .font(.subheadline)
            Text(preview.rule).font(.caption).foregroundStyle(.secondary)
            if let reset = preview.reset {
              Text("Resets on \(dateLabel(reset)).").font(.caption).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        } else {
          Text("Complete the cycle rule to preview its dates.").foregroundStyle(.secondary)
        }
      } header: {
        Text("Reward cycle")
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Prospective dates for today in Singapore. Earnings recalculate after Save.")
          if draft.billingType == .billing, (Int(draft.billingDay) ?? 0) >= 29 {
            Text("Short months use their last day.")
          }
          if configured(.qualification) {
            Text(
              "The board may count down to a monthly qualification deadline instead of this full period."
            )
          }
        }
      }

      Section("Spending targets") {
        numberField(
          "Minimum qualifying spend", text: $draft.minimumSpend, unit: currency, empty: "None")
        numberField(
          "Reward-earning spend cap", text: $draft.maximumSpend, unit: currency, empty: "No cap")
      }
      Section("Additional rules") {
        ForEach(Rule.allCases.filter { $0 != .display && configured($0) }) { rule in
          NavigationLink(value: Destination.rule(rule)) {
            VStack(alignment: .leading, spacing: 3) {
              Text(rule.rawValue)
              Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Menu("Add a rule…") {
          ForEach(Rule.allCases.filter { $0 != .display && !configured($0) }) { rule in
            Button(rule.rawValue) { path.append(.rule(rule)) }
          }
        }
      }
      Section { NavigationLink(Rule.display.rawValue, value: Destination.rule(.display)) }
      if isEditing {
        Section {
          Button("Remove Rewards…", role: .destructive) { isConfirmingDelete = true }
        }
      }
    }
  }

  private func ruleForm(_ rule: Rule) -> some View {
    draftForm {
      Section {
        Text("Changes stay in this draft. Return to Edit Rewards and Save to apply them.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      switch rule {
      case .display:
        Section {
          labelledField("Rewards label", text: $draft.name)
          labelledField("Issuer", text: $draft.issuer)
          Toggle("Featured", isOn: $draft.featured)
        } footer: {
          Text("Saved rewards metadata only. Edit Account separately to rename your account.")
        }
      case .qualification:
        Section {
          Picker("Period length", selection: $draft.rewardMonthCount) {
            Text("Not set").tag("")
            ForEach(2...24, id: \.self) { Text("\($0) months").tag(String($0)) }
          }
          dateField("First period starts", text: $draft.rewardAnchorDate)
          numberField("Minimum each month", text: $draft.rewardMonthlyMinimum, unit: currency)
        } footer: {
          Text(
            "Repeats from this anchor date. Once active, this rule takes precedence over promotion and billing dates. Each month's minimum must qualify separately."
          )
        }
        Section {
          Button("Remove qualification rule", role: .destructive) {
            draft.rewardMonthCount = ""; draft.rewardAnchorDate = "";
            draft.rewardMonthlyMinimum = ""
            path.removeLast()
          }
        }
      case .promotion:
        Section {
          dateField("Start date", text: $draft.promoStart)
          dateField("End date", text: $draft.promoEnd)
          labelledField("Description", text: $draft.promoDescription)
        } footer: {
          Text(
            "An unset start uses the current billing/calendar cycle start. A promotion overrides that cycle only within its dates; an active multi-month rule takes priority."
          )
        }
        Section {
          Button("Remove promotion", role: .destructive) {
            draft.promoStart = ""; draft.promoEnd = ""; draft.promoDescription = ""
            path.removeLast()
          }
        }
      case .rounding:
        Section {
          numberField(
            "Spend block size", text: $draft.earningBlockSize, unit: currency, empty: "None")
        } footer: {
          Text(
            "Spend is rounded down to complete blocks before rewards are calculated. Clear to remove the rule."
          )
        }
      case .flags:
        Section {
          ForEach(RewardFlagColour.allCases) { colour in
            colourNameRow(colour)
          }
        } header: {
          Text("Colour names")
        } footer: {
          Text("Names apply only to this account.")
        }

        Section {
          Toggle("Enable flag subcategories", isOn: $draft.subcategoriesEnabled)
          Picker("Import category", selection: $importCategoryId) {
            Text("Choose category").tag("")
            ForEach(importableCategories, id: \.id) { category in
              Text(category.name).tag(category.id)
            }
          }
          .accessibilityLabel("Import category")
          Picker("Flag colour", selection: importLedgerFlag) {
            ForEach(FlagColour.allCases) { colour in
              ledgerFlagOption(colour)
            }
          }
          numberField("Rate", text: $importRate, unit: rateUnit)
          Button("Add flag from category") {
            addImportedFlag()
          }
          ForEach(draft.flags) { flag in
            NavigationLink(draft.displayName(for: flag), value: Destination.flag(flag.id))
          }
          Button("Add flag") {
            withAnimation(Theme.Motion.standard) {
              draft.addFlag()
            }
          }
        } header: {
          Text("Flag subcategories")
        } footer: {
          Text(
            "These are the same colour tags as the ledger. None is Unflagged spend. Name the colour above and it appears on this account."
          )
        }

      case .tiers:
        Section("Spending tiers") {
          ForEach(draft.tiers) { tier in
            NavigationLink(
              "From \(tier.spendThreshold.isEmpty ? "…" : tier.spendThreshold) \(currency)",
              value: Destination.tier(tier.id))
          }
          Button("Add spending tier") {
            withAnimation(Theme.Motion.standard) {
              draft.addTier()
            }
          }
        }

      }
    }
    .navigationTitle(rule.rawValue)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func colourNameRow(_ colour: RewardFlagColour) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 5) {
        colourNameLabel(colour)
        colourNameField(colour)
      }
    } else {
      HStack {
        if colour == .unflagged {
          Text("None")
            .frame(width: 104, alignment: .leading)
        } else {
          Image(systemName: "flag.fill")
            .foregroundStyle(Theme.flagColour(named: colour.rawValue) ?? .secondary)
            .frame(width: 24)
          Text(colour.title)
            .frame(width: 72, alignment: .leading)
        }
        colourNameField(colour)
      }
    }
  }

  @ViewBuilder
  private func colourNameLabel(_ colour: RewardFlagColour) -> some View {
    if colour == .unflagged {
      Text("None")
    } else {
      Label {
        Text(colour.title)
      } icon: {
        Image(systemName: "flag.fill")
          .foregroundStyle(Theme.flagColour(named: colour.rawValue) ?? .secondary)
      }
    }
  }

  private func colourNameField(_ colour: RewardFlagColour) -> some View {
    TextField(
      colour == .unflagged ? "None" : colour.title, text: colourNameBinding(for: colour)
    )
    .accessibilityLabel("\(colour == .unflagged ? "None" : colour.title) name")
  }

  private func dateLabel(_ iso: String) -> String {
    RewardsCalendar.shortLabel(iso, referenceISO: RewardsCalendar.today())
  }

  private func draftForm<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
    ScrollViewReader { proxy in
      Form {
        errorSection
        content()
      }
      .disabled(isSaving || isDeleting)
      .scrollContentBackground(.hidden)
      .contentMargins(.bottom, 24, for: .scrollContent)
      .onChange(of: errorRevision) { proxy.scrollTo("editor-error", anchor: .top) }
      .onAppear { if errorMessage != nil { proxy.scrollTo("editor-error", anchor: .top) } }
    }
  }

  private func flagBinding(_ id: String) -> Binding<RewardFlagDraft>? {
    guard let initial = draft.flags.first(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { draft.flags.first(where: { $0.id == id }) ?? initial },
      set: { value in
        if let index = draft.flags.firstIndex(where: { $0.id == id }) { draft.flags[index] = value }
      })
  }

  private func tierBinding(_ id: String) -> Binding<RewardTierDraft>? {
    guard let initial = draft.tiers.first(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { draft.tiers.first(where: { $0.id == id }) ?? initial },
      set: { value in
        if let index = draft.tiers.firstIndex(where: { $0.id == id }) { draft.tiers[index] = value }
      })
  }

  @ViewBuilder
  private var errorSection: some View {
    if let errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(Theme.outflow)
        if originalDraft == nil {
          Button("Retry loading") { Task { await loadCard() } }
        }
      }.id("editor-error")
    }
  }

  private func configured(_ rule: Rule) -> Bool {
    switch rule {
    case .flags:
      return !draft.flags.isEmpty || !draft.flagNames.isEmpty || draft.subcategoriesEnabled
    case .tiers: return !draft.tiers.isEmpty
    case .qualification:
      return !draft.rewardMonthCount.isEmpty || !draft.rewardAnchorDate.isEmpty
        || !draft.rewardMonthlyMinimum.isEmpty
    case .promotion:
      return !draft.promoStart.isEmpty || !draft.promoEnd.isEmpty || !draft.promoDescription.isEmpty
    case .rounding: return !draft.earningBlockSize.isEmpty
    case .display: return true
    }
  }

  private func summary(_ rule: Rule) -> String {
    switch rule {
    case .flags:
      return
        "\(draft.flags.count) rules · \(draft.subcategoriesEnabled ? "Enabled" : "Disabled; rules retained")"
    case .tiers: return "\(draft.tiers.count) tiers"
    case .qualification: return "\(draft.rewardMonthCount) months · from \(draft.rewardAnchorDate)"
    case .promotion: return "Until \(draft.promoEnd)"
    case .rounding: return "Blocks of \(draft.earningBlockSize) \(currency)"
    case .display: return draft.name
    }
  }

  private func labelledField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.subheadline).foregroundStyle(.secondary)
      TextField(label, text: text).accessibilityLabel(label)
    }
  }

  private func numberField(
    _ label: String, text: Binding<String>, unit: String, empty: String = "Not set"
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        Text(label).fixedSize(horizontal: true, vertical: false)
        TextField(empty, text: text).multilineTextAlignment(.trailing)
          .frame(minWidth: 70).keyboardType(.decimalPad).accessibilityLabel(label)
        Text(unit).foregroundStyle(.secondary).fixedSize()
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(label).font(.subheadline)
        HStack {
          TextField(empty, text: text)
            .keyboardType(.decimalPad).accessibilityLabel(label)
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func dateField(_ label: String, text: Binding<String>) -> some View {
    if text.wrappedValue.isEmpty {
      Button("\(label): Not set") { text.wrappedValue = RewardsCalendar.today() }
    } else {
      DatePicker(
        label,
        selection: Binding(
          get: { RewardsCalendar.date(text.wrappedValue) ?? Date() },
          set: { text.wrappedValue = RewardsCalendar.isoString($0) }
        ), displayedComponents: .date
      )
      .environment(\.calendar, RewardsCalendar.calendar)
      .environment(\.timeZone, RewardsCalendar.timeZone)
      Button("Clear \(label.lowercased())") { text.wrappedValue = "" }
    }
  }

  @ViewBuilder
  private func flagEditor(_ flag: Binding<RewardFlagDraft>) -> some View {
    let index = draft.flags.firstIndex(where: { $0.id == flag.wrappedValue.id }) ?? 0
    Section {
      labelledField("Colour name", text: colourNameBinding(for: flag.wrappedValue.flagColor))
      Picker(
        "Flag colour",
        selection: Binding(
          get: { flag.wrappedValue.flagColor.ledgerColour },
          set: { nextColour in
            let next = RewardFlagColour(ledgerColour: nextColour)
            if (draft.flagNames[next] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
              draft.flagNames[next] = flag.wrappedValue.name
            }
            flag.wrappedValue.flagColor = next
            flag.wrappedValue.touch()
          }
        )
      ) {
        ForEach(FlagColour.allCases) { colour in
          ledgerFlagOption(colour)
        }
      }
      .accessibilityLabel("Flag \(index + 1) colour")
      numberField(
        "Reward value",
        text: Binding(
          get: { flag.wrappedValue.rewardValue },
          set: {
            flag.wrappedValue.rewardValue = $0; flag.wrappedValue.touch()
          }
        ), unit: rateUnit
      )
      .accessibilityLabel("Flag \(index + 1) reward value")
      numberField(
        "Priority",
        text: Binding(
          get: { flag.wrappedValue.priority },
          set: {
            flag.wrappedValue.priority = $0; flag.wrappedValue.touch()
          }
        ), unit: ""
      )
      .accessibilityLabel("Flag \(index + 1) priority")
      numberField(
        "Minimum spend",
        text: Binding(
          get: { flag.wrappedValue.minimumSpend },
          set: {
            flag.wrappedValue.minimumSpend = $0; flag.wrappedValue.touch()
          }
        ), unit: currency, empty: "None")
      numberField(
        "Maximum spend",
        text: Binding(
          get: { flag.wrappedValue.maximumSpend },
          set: {
            flag.wrappedValue.maximumSpend = $0; flag.wrappedValue.touch()
          }
        ), unit: currency, empty: "No cap")
      numberField(
        "Miles spend block",
        text: Binding(
          get: { flag.wrappedValue.milesBlockSize },
          set: {
            flag.wrappedValue.milesBlockSize = $0; flag.wrappedValue.touch()
          }
        ), unit: currency, empty: "None")
      Toggle(
        "Active",
        isOn: Binding(
          get: { flag.wrappedValue.active },
          set: {
            flag.wrappedValue.active = $0; flag.wrappedValue.touch()
          }
        ))
      Toggle(
        "Exclude from rewards",
        isOn: Binding(
          get: { flag.wrappedValue.excludeFromRewards },
          set: {
            flag.wrappedValue.excludeFromRewards = $0; flag.wrappedValue.touch()
          }
        ))
      Button("Remove", role: .destructive) {
        let id = flag.wrappedValue.id
        path.removeLast()
        draft.flags.removeAll { $0.id == id }
        for index in draft.tiers.indices {
          draft.tiers[index].overrides.removeAll { $0.subcategoryId == id }
        }
      }
    } footer: {
      Text("Removing this flag also removes its overrides from spending tiers.")
    }
  }

  @ViewBuilder
  private func tierEditor(_ tier: Binding<RewardTierDraft>) -> some View {
    Section {
      numberField("Spend threshold", text: tier.spendThreshold, unit: currency)
      numberField("Earning rate", text: tier.earningRate, unit: rateUnit)
      numberField("Maximum spend", text: tier.maximumSpend, unit: currency, empty: "No cap")
      ForEach(tier.overrides) { $override in
        Picker("Flag override", selection: $override.subcategoryId) {
          Text("Choose flag").tag("")
          ForEach(draft.flags) { flag in
            Text(draft.displayName(for: flag)).tag(flag.id)
          }
        }
        numberField("Override rate", text: $override.rewardValue, unit: rateUnit)
        numberField(
          "Override maximum", text: $override.maximumSpend, unit: currency, empty: "No cap")
        Button("Remove override", role: .destructive) {
          tier.wrappedValue.overrides.removeAll { $0.id == override.id }
        }
      }
      Button("Add flag override") {
        withAnimation(Theme.Motion.standard) {
          tier.wrappedValue.overrides.append(
            RewardTierOverrideDraft(subcategoryId: draft.flags.first?.id ?? "")
          )
        }
      }
      Button("Remove tier", role: .destructive) {
        let id = tier.wrappedValue.id
        path.removeLast()
        draft.tiers.removeAll { $0.id == id }
      }
    }
  }

  @ViewBuilder
  private func ledgerFlagOption(_ colour: FlagColour) -> some View {
    HStack {
      Image(systemName: colour == .none ? "flag" : "flag.fill")
        .foregroundStyle(Theme.flagColour(named: colour.rawValue) ?? .secondary)
      Text(draft.ledgerTitle(for: colour))
    }
    .tag(colour)
  }

  private func colourNameBinding(for colour: RewardFlagColour) -> Binding<String> {
    Binding(
      get: { draft.flagNames[colour] ?? "" },
      set: { value in
        draft.flagNames[colour] = value
        for index in draft.flags.indices where draft.flags[index].flagColor == colour {
          draft.flags[index].name = value
          draft.flags[index].touch()
        }
      }
    )
  }

  private var importLedgerFlag: Binding<FlagColour> {
    Binding(
      get: { importFlagColor.ledgerColour },
      set: { importFlagColor = RewardFlagColour(ledgerColour: $0) }
    )
  }

  private var accountChoices: [Account] {
    RewardCardAccounts.choices(
      accounts: model.accounts,
      takenIDs: takenAccountIDs,
      keepingID: draft.ynabAccountId.isEmpty ? nil : draft.ynabAccountId
    )
  }

  private var importableCategories: [Category] {
    model.categoryGroups
      .filter { !$0.deleted }
      .flatMap { group in
        group.categories.filter { !$0.deleted }
      }
  }

  private func addImportedFlag() {
    let name = model.categoryName(forID: importCategoryId) ?? ""
    guard !importCategoryId.isEmpty, !name.isEmpty else {
      showError("Choose a category to add as a flag.")
      return
    }
    do {
      try draft.addImportedFlag(name: name, flagColor: importFlagColor, rewardValue: importRate)
      errorMessage = nil
      importCategoryId = ""
      importRate = ""
    } catch {
      showError(error.localizedDescription)
    }
  }

  private func loadCard() async {
    guard originalDraft == nil else { return }
    loadPhase = .loading
    errorMessage = nil
    do {
      let snapshot = try await model.apiClient.fetchRewardsTrackerSnapshot(
        planID: model.settings.planID)
      takenAccountIDs = Set(
        snapshot.cards
          .filter { $0.id != cardID }
          .map(\.ynabAccountId)
          .filter { !$0.isEmpty }
      )
      if let cardID {
        guard let card = snapshot.cards.first(where: { $0.id == cardID }) else {
          loadPhase = .failed("This card is not stored on this plan.")
          return
        }
        draft = RewardCardDraft(card: card)
      } else {
        draft = .empty()
      }
      originalDraft = draft
      loadPhase = .loaded
    } catch {
      loadPhase = .failed(error.localizedDescription)
      showError(error.localizedDescription)
    }
  }

  private func save() async {
    let written: CreditCard
    do {
      written = try draft.write()
    } catch {
      showError(error.localizedDescription)
      let message = error.localizedDescription.lowercased()
      let words = message.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      if words.starts(with: ["spending", "tier"]), words.count > 2,
        let number = Int(words[2]), draft.tiers.indices.contains(number - 1)
      {
        path = [.rule(.tiers), .tier(draft.tiers[number - 1].id)]
        return
      }
      if words.first == "flag", words.count > 1,
        let number = Int(words[1]), draft.flags.indices.contains(number - 1)
      {
        path = [.rule(.flags), .flag(draft.flags[number - 1].id)]
        return
      }
      let rule: Rule? =
        if message.contains("spending tier") {
          .tiers
        } else if message.contains("flag") || message.contains("colour") {
          .flags
        } else if message.contains("reward period") || message.contains("anchor")
          || message.contains("monthly minimum")
        { .qualification } else if message.contains("promotional") {
          .promotion
        } else if message.contains("block size") {
          .rounding
        } else if message.contains("rewards label") { .display } else { nil }
      path = rule.map { [.rule($0)] } ?? []
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
      showError(
        "Could not save rewards. \(error.localizedDescription) Your draft is kept; try Save again.")
      isSaving = false
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    errorRevision += 1
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
      showError(error.localizedDescription)
      isDeleting = false
    }
  }
}
