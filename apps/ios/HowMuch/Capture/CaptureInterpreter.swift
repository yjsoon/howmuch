import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum CaptureIntelligenceStatus: Equatable, Sendable {
  case available
  case downloading
  case unavailable
  case error(String)

  var allowsDescribe: Bool {
    switch self {
    case .available, .downloading:
      return true
    case .unavailable, .error:
      return false
    }
  }

  var banner: String? {
    switch self {
    case .available:
      return nil
    case .downloading:
      return "Apple Intelligence is still downloading. You can still type; Manual works now."
    case .unavailable:
      return "Apple Intelligence is not available on this device. Enter manually, or try again on a supported iPhone."
    case .error(let message):
      return message
    }
  }

  static var current: CaptureIntelligenceStatus {
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .available:
      return .available
    case .unavailable(let reason):
      if case .modelNotReady = reason {
        return .downloading
      }
      return .unavailable
    @unknown default:
      return .available
    }
    #else
    return .unavailable
    #endif
  }
}

struct CaptureTurnContext: Equatable, Sendable {
  var text: String
  var selectedAccountName: String
  var selectedAccountID: String
  var today: String
  var drafts: [CaptureDraftPromptRow]
  var priorInstructions: [String]
  var priorAnswers: [String]
  var attachmentTranscripts: [String]
}

struct CaptureDraftPromptRow: Equatable, Sendable {
  var id: String
  var payee: String
  var amount: String
  var account: String
  var category: String
  var date: String
}

enum CaptureInterpreterPrompt {
  static let instructions = """
  You are HowMuch's on-device capture helper. Today's local date is the calendar date. Do not invent ledger totals. Do not delete saved transactions.

  Current drafts and the selected account are capture-only. Use them only for add and update. They are not spending-query scope.

  Classify the instruction:
  - add: new spend or income to append as new drafts
  - update: change one or more existing drafts (amount, date, account, category, payee)
  - query: a read-only question about recorded spending
  - unsupported: anything else, including editing or deleting already saved ledger rows

  For add and update, return spends with decimal amounts such as 5 or 5.00, never milliunits or IDs. Copy account and category names from the provided lists when they match. Leave a field empty when it was not mentioned. When the user does not name an account, leave account empty so the selected account can fill it. When they name an account, copy that name even if it is ambiguous.

  For update, set targetDraftID to the existing draft id when the user is clearly talking about that row. Leave it empty when a single draft exists or when the change applies to every current draft (applyToAllDrafts true). If two drafts could match and the user did not say which, leave targetDraftID empty and applyToAllDrafts false.

  For query, fill queryKind as spending, today, spendingThisMonth, compareCategory, or findMerchant. Named merchant payment lookup uses findMerchant. A merchant-filtered spending report or category comparison that cannot be represented must be declined as unsupported; never drop the merchant to manufacture an unfiltered report. Do not put a merchant on spending, today, spendingThisMonth, or compareCategory. Query scope comes from the latest spending question, or from a follow-up that continues a prior spending query. Never copy the selected capture account, a prior add or update instruction, or a current unsaved draft into queryAccount, queryCategory, queryMerchant, or spends. For an unqualified Today question, use all accounts, all categories, and no merchant: leave queryAccount, queryCategory, and queryMerchant empty, and leave spends empty. Preserve any dates the user named. Optional from and to are yyyy-MM-dd. Use today only for this local calendar day. Do not rewrite yesterday or last month as this month.

  Feedback is warm, concise conversational British English: one or two short sentences, with contractions. Do not write robotic status fragments or cheerleading. For add and update, call it a draft ready for review and make clear it is not saved yet. Never claim that anything was saved, and never invent actions or results. Questions and clarifications stay natural and truthful.
  """

  static func prefix(
    context: CaptureTurnContext,
    accounts: [Account],
    categoryGroups: [CategoryGroup]
  ) -> String {
    let accountNames = accounts.filter { !$0.closed && !$0.deleted }.map(\.name)
    let categoryNames = categoryGroups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }.map(\.name)
    }
    let draftLines = context.drafts.isEmpty
      ? "none"
      : context.drafts.map { row in
        "id=\(row.id) payee=\(row.payee) amount=\(row.amount) account=\(row.account) category=\(row.category) date=\(row.date)"
      }.joined(separator: "\n")
    let prior = context.priorInstructions.isEmpty
      ? "none"
      : context.priorInstructions.joined(separator: "\n")
    let answers = context.priorAnswers.isEmpty
      ? "none"
      : context.priorAnswers.joined(separator: "\n")
    let transcripts = context.attachmentTranscripts.isEmpty
      ? "none"
      : context.attachmentTranscripts.joined(separator: "\n---\n")
    return """
    Today: \(context.today)
    Selected account: \(context.selectedAccountName)
    Accounts: \(accountNames.joined(separator: ", "))
    Categories: \(categoryNames.joined(separator: ", "))

    Current drafts:
    \(draftLines)

    Prior instructions:
    \(prior)

    Prior answers:
    \(answers)

    Selected account and current drafts apply only to add and update. An unqualified spending question does not inherit them.

    Attachment text:
    \(transcripts)

    Instruction:

    """
  }

  @MainActor
  static func context(
    text: String,
    session: CaptureSession,
    accounts: [Account],
    categoryGroups: [CategoryGroup] = [],
    calendar: Calendar = .current,
    now: Date = .now,
    attachmentIDs: [UUID]? = nil,
    frozen: CaptureFrozenTurn? = nil
  ) -> CaptureTurnContext {
    let accountID: String?
    if let frozen {
      accountID = frozen.accountID
    } else {
      accountID = session.selectedAccountID
    }
    let selected = accountID.flatMap { id in
      accounts.first(where: { $0.id == id })
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return CaptureTurnContext(
      text: text,
      selectedAccountName: frozen.map(\.accountName) ?? selected?.name ?? "Choose Account",
      selectedAccountID: accountID ?? "",
      today: frozen?.localDate ?? formatter.string(from: calendar.startOfDay(for: now)),
      drafts: session.currentDrafts.map { item in
        CaptureDraftPromptRow(
          id: item.id,
          payee: item.draft.payeeName,
          amount: MoneyCodec.displayString(for: item.draft.signedMilliunits, currencyFormat: nil),
          account: accounts.first(where: { $0.id == item.draft.accountID })?.name ?? "",
          category: categoryName(item.draft.categoryID, in: categoryGroups),
          date: formatter.string(from: item.draft.date)
        )
      },
      priorInstructions: session.messages.filter { $0.kind == .user }.suffix(6).map(\.text),
      priorAnswers: session.messages.filter { $0.kind == .assistant }.suffix(4).map(\.text),
      attachmentTranscripts: transcripts(from: session, attachmentIDs: attachmentIDs)
    )
  }

  @MainActor
  private static func transcripts(from session: CaptureSession, attachmentIDs: [UUID]?) -> [String] {
    let source: [CaptureAttachment]
    if let attachmentIDs {
      let wanted = Set(attachmentIDs)
      source = session.persistableAttachments.filter { wanted.contains($0.id) }
    } else {
      source = session.attachments
    }
    return source.map(\.recognizedText).filter { !$0.isEmpty }
  }

  private static func categoryName(_ id: String?, in groups: [CategoryGroup]) -> String {
    guard let id else {
      return ""
    }
    return groups.lazy.flatMap(\.categories).first(where: { $0.id == id })?.name ?? ""
  }
}

actor CaptureInterpreter {
  enum Backend: Sendable {
    case foundationModels
    case fixed(@Sendable (CaptureTurnContext) -> CaptureInterpretedTurn)
  }

  static let shared = CaptureInterpreter()

  private let backend: Backend

  init(backend: Backend = .foundationModels) {
    self.backend = backend
  }

  func interpret(
    context: CaptureTurnContext,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar = .current,
    now: Date = .now
  ) async -> Result<(CaptureInterpretedTurn, [CaptureMappedChange]), CaptureInterpreterError> {
    let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentText = context.attachmentTranscripts.joined(separator: "\n")
    guard !trimmed.isEmpty || !attachmentText.isEmpty else {
      return .failure(.empty)
    }
    let turn: CaptureInterpretedTurn
    switch backend {
    case .foundationModels:
      do {
        turn = try await extractWithModel(
          context: context,
          accounts: accounts,
          categoryGroups: categoryGroups
        )
      } catch let error as CaptureInterpreterError {
        return .failure(error)
      } catch {
        return .failure(.model(error.localizedDescription))
      }
    case .fixed(let produce):
      turn = produce(context)
    }

    let mappingNow = SlipReaderMapping.date(from: context.today, calendar: calendar, now: now)
      ?? calendar.startOfDay(for: now)
    let changes: [CaptureMappedChange] = turn.mutations.compactMap { mutation in
      guard !mutation.extraction.isBlank else {
        return nil
      }
      let mapped = SlipReaderMapping.map(
        [mutation.extraction],
        accounts: accounts,
        categoryGroups: categoryGroups,
        payees: payees,
        calendar: calendar,
        now: mappingNow
      )
      guard let row = mapped.first else {
        return nil
      }
      return CaptureMappedChange(targetDraftID: mutation.targetDraftID, mapped: row)
    }
    return .success((turn, changes))
  }

  private func extractWithModel(
    context: CaptureTurnContext,
    accounts: [Account],
    categoryGroups: [CategoryGroup]
  ) async throws -> CaptureInterpretedTurn {
    #if canImport(FoundationModels)
    switch CaptureIntelligenceStatus.current {
    case .unavailable:
      throw CaptureInterpreterError.unavailable
    case .error(let message):
      throw CaptureInterpreterError.model(message)
    case .available, .downloading:
      break
    }
    let prefix = CaptureInterpreterPrompt.prefix(
      context: context,
      accounts: accounts,
      categoryGroups: categoryGroups
    )
    let session = LanguageModelSession(instructions: CaptureInterpreterPrompt.instructions)
    let prompt = prefix + context.text
    let response = try await session.respond(
      to: prompt,
      generating: GenerableCaptureTurn.self,
      options: GenerationOptions(sampling: .greedy)
    )
    return Self.mapPayload(Self.plainPayload(from: response.content))
    #else
    throw CaptureInterpreterError.unavailable
    #endif
  }

  static func mapPayload(_ payload: CaptureTurnPayload) -> CaptureInterpretedTurn {
    let intent = CaptureTurnIntent(rawValue: payload.kind.lowercased()) ?? .unsupported
    let mutations = payload.spends.map { spend in
      CaptureDraftMutation(
        targetDraftID: spend.targetDraftID.isEmpty ? nil : spend.targetDraftID,
        extraction: SlipReaderMapping.Extraction(
          amount: spend.amount,
          payee: spend.payee,
          category: spend.category,
          account: spend.account,
          date: spend.date,
          isInflow: spend.isInflow,
          direction: spend.direction
        )
      )
    }
    let query: LedgerQuerySpec?
    if intent == .query {
      query = LedgerQuerySpec(
        kind: Self.queryKind(from: payload.queryKind),
        category: payload.queryCategory,
        account: payload.queryAccount,
        merchant: payload.queryMerchant,
        from: payload.queryFrom,
        to: payload.queryTo
      )
    } else {
      query = nil
    }
    return CaptureInterpretedTurn(
      intent: intent,
      feedback: payload.feedback,
      mutations: mutations,
      query: query,
      applyToAllDrafts: payload.applyToAllDrafts
    )
  }

  private static func queryKind(from raw: String) -> LedgerQueryKind {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let kind = LedgerQueryKind(rawValue: trimmed) {
      return kind
    }
    switch trimmed.lowercased() {
    case "other", "spend", "spendingrange", "range":
      return .spending
    case "this month", "month":
      return .spendingThisMonth
    default:
      return .unsupported
    }
  }
}

enum CaptureInterpreterError: Equatable, LocalizedError, Sendable {
  case empty
  case unavailable
  case cancelled
  case model(String)

  var errorDescription: String? {
    switch self {
    case .empty:
      return "Type a spend, attach a slip, or ask a question."
    case .unavailable:
      return "Apple Intelligence is not available. Nothing was changed. Use Manual if you want to enter the transaction yourself."
    case .cancelled:
      return "That request was cancelled. Your drafts are still here."
    case .model(let message):
      return "I could not read that. \(message) Your drafts are still here."
    }
  }
}

struct CaptureTurnPayload: Equatable, Sendable {
  var kind = "unsupported"
  var feedback = ""
  var applyToAllDrafts = false
  var spends: [CaptureTurnSpend] = []
  var queryKind = ""
  var queryCategory = ""
  var queryAccount = ""
  var queryMerchant = ""
  var queryFrom = ""
  var queryTo = ""
}

struct CaptureTurnSpend: Equatable, Sendable {
  var targetDraftID = ""
  var amount = ""
  var payee = ""
  var category = ""
  var account = ""
  var date = ""
  var isInflow = false
  var direction = ""
}

#if canImport(FoundationModels)
@Generable
struct GenerableCaptureTurn {
  @Guide(description: "add, update, query, or unsupported. Use unsupported when a merchant-filtered report or comparison cannot be represented.")
  var kind: String
  @Guide(description: "Warm concise British English, one or two short sentences, contractions. For add or update say it is a draft ready for review and is not saved yet. Never claim anything was saved or invent actions or results. No robotic status fragments or cheerleading.")
  var feedback: String
  @Guide(description: "True when the update applies to every current draft")
  var applyToAllDrafts: Bool
  @Guide(description: "New or changed spends for add or update. Empty for query.")
  var spends: [GenerableCaptureSpend]
  @Guide(description: "Query kind when kind is query: spending, today, spendingThisMonth, compareCategory, or findMerchant. Use findMerchant for a named merchant payment lookup. Never use spending, today, spendingThisMonth, or compareCategory with a merchant; decline that as unsupported instead of dropping the merchant.")
  var queryKind: String
  @Guide(description: "Named category from the latest spending question or an explicit spending-query follow-up. Empty unless that question or follow-up named a category. Never from capture drafts or the selected account.")
  var queryCategory: String
  @Guide(description: "Named account from the latest spending question or an explicit spending-query follow-up. Empty unless that question or follow-up named an account. Never the selected capture account.")
  var queryAccount: String
  @Guide(description: "Named merchant for findMerchant lookup from the latest spending question or an explicit spending-query follow-up. Empty unless that question or follow-up named a merchant. Never set this on spending, today, spendingThisMonth, or compareCategory, and never drop a named merchant to manufacture an unfiltered report.")
  var queryMerchant: String
  @Guide(description: "Query start date yyyy-MM-dd from the latest spending question or an explicit spending-query follow-up. Empty when none was named.")
  var queryFrom: String
  @Guide(description: "Query end date yyyy-MM-dd from the latest spending question or an explicit spending-query follow-up. Empty when none was named.")
  var queryTo: String
}

@Generable
struct GenerableCaptureSpend {
  @Guide(description: "Existing draft id for an update, otherwise empty")
  var targetDraftID: String
  @Guide(description: "Amount as a decimal string like 5.00, no currency symbol")
  var amount: String
  var payee: String
  var category: String
  var account: String
  var date: String
  var isInflow: Bool
  @Guide(description: "inflow, outflow, or empty if direction was not mentioned")
  var direction: String
}

extension CaptureInterpreter {
  static func plainPayload(from generated: GenerableCaptureTurn) -> CaptureTurnPayload {
    CaptureTurnPayload(
      kind: generated.kind,
      feedback: generated.feedback,
      applyToAllDrafts: generated.applyToAllDrafts,
      spends: generated.spends.map {
        CaptureTurnSpend(
          targetDraftID: $0.targetDraftID,
          amount: $0.amount,
          payee: $0.payee,
          category: $0.category,
          account: $0.account,
          date: $0.date,
          isInflow: $0.isInflow,
          direction: $0.direction
        )
      },
      queryKind: generated.queryKind,
      queryCategory: generated.queryCategory,
      queryAccount: generated.queryAccount,
      queryMerchant: generated.queryMerchant,
      queryFrom: generated.queryFrom,
      queryTo: generated.queryTo
    )
  }
}
#endif
