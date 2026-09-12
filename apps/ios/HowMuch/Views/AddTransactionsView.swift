import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TransactionFormChrome: Equatable {
  case standalone
  case sessionEditor
}

struct AddTransactionsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Bindable var session: CaptureSession
  var embeddedInAssistant = false

  @State private var editingDraftID: String?
  @State private var errorMessage: String?
  private let interpreter: CaptureInterpreter?
  @State private var showingAISettings = false
  @State private var isShowingCamera = false
  @State private var isShowingLibraryPicker = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var cameraUnavailableMessage: String?
  @State private var isComposerFocused = false
  @State private var claimComposerFocus = false
  @State private var didConsumeEntryFocus = false
  @State private var isShowingPlus = false
  @State private var creatingManual = false
  @State private var isConfirmingDiscard = false
  @State private var highlightDraftID: String?
  @State private var inspectAttachment: CaptureAttachment?
  @State private var jumpToMessage: UUID?
  @State private var isNearBottom = true
  @State private var showJumpToLatest = false
  @State private var showingAccountPicker = false
  @State private var resolvingAccountDraftID: String?
  @State private var resolvingCategoryDraftID: String?
  @State private var inspectQueryCard: LedgerQueryResult?
  @State private var groupSaveErrors: [UUID: String] = [:]
  private let workspace: CaptureWorkspace

  init(
    session: CaptureSession,
    embeddedInAssistant: Bool = false,
    interpreter: CaptureInterpreter? = nil,
    workspace: CaptureWorkspace = .shared
  ) {
    self.session = session
    self.embeddedInAssistant = embeddedInAssistant
    self.interpreter = interpreter
    self.workspace = workspace
  }

  var body: some View {
    wrapped {
      conversation
        .background(Theme.canvas)
        .navigationTitle(embeddedInAssistant ? "Conversation" : "Add Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              isComposerFocused = false
              showingAISettings = true
            } label: {
              Label("AI provider", systemImage: "sparkles")
                .labelStyle(.iconOnly)
            }
            .tint(Theme.accent)
            .accessibilityLabel("AI provider")
            .accessibilityValue(model.captureAI.displayName)
          }
          if embeddedInAssistant {
            ToolbarItem(placement: .topBarTrailing) {
              Menu {
                Button("Connection settings") { model.isShowingSettings = true }
                Button("Discard this conversation", role: .destructive) {
                  isConfirmingDiscard = true
                }
              } label: {
                Label("More", systemImage: "ellipsis.circle")
              }
              .tint(Theme.accent)
            }
          } else {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") {
                workspace.persistCurrentIfNeeded()
                dismiss()
              }
              .tint(Theme.accent)
            }
          }
        }
        .toolbar(embeddedInAssistant ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
          CaptureComposerDock(
            text: $session.composerText,
            isFocused: $isComposerFocused,
            claimFocus: claimComposerFocus,
            accountLabel: currentAccountName,
            isBusy: session.isBusy,
            isIngesting: session.isIngesting,
            canSend: session.canSendComposer,
            canChangeAccount: !session.isBusy && !session.isSaving,
            canOpenPlus: !session.isSaving,
            pending: session.attachments,
            ingestError: errorMessage,
            onAccount: { if !session.isBusy && !session.isSaving { editingDraftID = nil; showingAccountPicker = true } },
            onPlus: { if !session.isSaving { isShowingPlus = true } },
            onSend: send,
            onStop: stopReply,
            onImages: { beginIngest(images: $0, filenamePrefix: "paste") },
            onRemove: { session.removeAttachment($0) },
            onRetry: { retryReadingImage($0) },
            onAddManually: beginManualEntry
          )
        }
      .navigationDestination(isPresented: Binding(
        get: { editingDraftID != nil },
        set: { if !$0 { editingDraftID = nil } }
      )) {
        if let id = editingDraftID, let item = session.drafts.first(where: { $0.id == id }) {
          TransactionFormView(
            draft: item.draft,
            isEditing: false,
            allowsDeletion: false,
            chrome: .sessionEditor,
            onPersist: { updated in
              session.applyManualEdit(updated, id: id)
            }
          )
        }
      }
      .sheet(isPresented: $showingAISettings) {
        NavigationStack { CaptureAISettingsView(settings: model.captureAI) }
          .blocksCapturePresentation()
      }
      .sheet(isPresented: $creatingManual) {
        TransactionFormView(
          draft: seededManualDraft(),
          isEditing: false,
          allowsDeletion: false
        )
        .presentationDetents([.large])
        .blocksCapturePresentation()
      }
      .navigationDestination(isPresented: Binding(
        get: { inspectQueryCard != nil },
        set: { if !$0 { inspectQueryCard = nil } }
      )) {
        if let card = inspectQueryCard {
          QuerySourceListView(card: card, currencyFormat: model.currencyFormat)
        }
      }
      .navigationDestination(isPresented: $showingAccountPicker) {
        AccountPickerView(selectedAccountID: session.selectedAccountID ?? "") { account in
          session.selectAccount(account.id, accounts: model.openAccounts)
        }
      }
      .navigationDestination(isPresented: Binding(
        get: { resolvingAccountDraftID != nil },
        set: { if !$0 { resolvingAccountDraftID = nil } }
      )) {
        AccountPickerView(selectedAccountID: "") { account in
          if let id = resolvingAccountDraftID {
            session.resolveAccount(account.id, forDraft: id)
          }
        }
      }
      .navigationDestination(isPresented: Binding(
        get: { resolvingCategoryDraftID != nil },
        set: { if !$0 { resolvingCategoryDraftID = nil } }
      )) {
        CaptureNamePickList(
          title: "Category",
          names: model.flattenedCategories.map { ($0.id, $0.name) }
        ) { id in
          if let draftID = resolvingCategoryDraftID {
            session.resolveCategory(id, forDraft: draftID)
          }
        }
      }
      .sheet(isPresented: $isShowingPlus) {
        plusMenu
      }
      .photosPicker(isPresented: $isShowingLibraryPicker, selection: $photoItems, matching: .images)
      .onChange(of: photoItems) { _, items in
        beginIngest(pickerItems: items)
      }
      .fullScreenCover(isPresented: $isShowingCamera) {
        CameraPicker { image in
          beginIngest(images: [image], filenamePrefix: "camera")
        }
      }
      .sheet(item: $inspectAttachment) { attachment in
        if let image = UIImage(data: attachment.data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .padding()
            .presentationDetents([.large])
        }
      }
      .alert(
        "Camera unavailable",
        isPresented: Binding(
          get: { cameraUnavailableMessage != nil },
          set: { if !$0 { cameraUnavailableMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(cameraUnavailableMessage ?? "")
      }
      .binaryConfirm(
        "Discard this conversation?",
        isPresented: $isConfirmingDiscard,
        confirm: .destructive("Discard")
      ) {
        workspace.discardCurrent()
      }
    }
    .onAppear {
      workspace.activate(scopeKey: model.settings.viewPrefsScopeKey)
      session.hydrateOwnershipIfNeeded()
      guard !didConsumeEntryFocus else {
        return
      }
      didConsumeEntryFocus = true
      let blankChat = session.messages.isEmpty && session.drafts.isEmpty && session.sentAttachments.isEmpty
      let imageEntry = !session.attachments.isEmpty && session.composerText.isEmpty
      if blankChat, !imageEntry {
        claimComposerFocus = true
      }
    }
    .onChange(of: isComposerFocused) { _, focused in
      if focused {
        claimComposerFocus = false
      }
    }
    .onChange(of: session.composerText) { _, _ in
      workspace.requestPersistCurrent()
    }
    .onChange(of: session.revision) { _, _ in
      workspace.requestPersistCurrent()
    }
    .onChange(of: highlightDraftID) { _, id in
      guard let id else {
        return
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.5))
        if highlightDraftID == id {
          highlightDraftID = nil
        }
      }
    }
  }

  @ViewBuilder
  private func wrapped(@ViewBuilder content: () -> some View) -> some View {
    if embeddedInAssistant {
      content()
    } else {
      NavigationStack {
        content()
      }
    }
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if let banner = intelligence.banner {
            Text(banner)
              .font(.footnote)
              .foregroundStyle(Theme.uncategorised)
          }
          ForEach(session.messages) { message in
            turnView(message)
              .id(message.id)
          }
          Color.clear
            .frame(height: 1)
            .id("conversation-end")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
      }
      .scrollDismissesKeyboard(.interactively)
      .onScrollGeometryChange(for: Bool.self) { geometry in
        let remaining = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
        return remaining < 80
      } action: { _, near in
        isNearBottom = near
        if near {
          showJumpToLatest = false
        }
      }
      .onChange(of: session.revision) { _, _ in
        if isNearBottom {
          revealLatest(proxy)
        } else if session.messages.contains(where: { $0.replyState == .complete || $0.replyState == .failed || $0.replyState == .stopped }) {
          showJumpToLatest = true
        }
      }
      .onChange(of: jumpToMessage) { _, id in
        if let id {
          withAnimation {
            proxy.scrollTo(id, anchor: .top)
          }
          jumpToMessage = nil
        }
      }
      .overlay(alignment: .bottom) {
        if showJumpToLatest, !isNearBottom {
          Button("New response") {
            showJumpToLatest = false
            isNearBottom = true
            revealLatest(proxy)
          }
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Theme.card, in: Capsule())
          .padding(.bottom, 8)
          .accessibilityLabel("Jump to latest response")
        }
      }
    }
  }

  @ViewBuilder
  private func turnView(_ message: CaptureMessage) -> some View {
    switch message.kind {
    case .user:
      CaptureUserBubble(
        message: message,
        attachments: session.sentAttachments.filter { message.attachmentIDs.contains($0.id) },
        inspect: { inspectAttachment = $0 }
      )
    case .system:
      Text(message.text)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if message.queryID != nil
        || !ownedDrafts(for: message).isEmpty
        || session.canUndo(ownedIDs: message.ownedDraftIDs)
      {
        assistantReply(message, showsProse: false)
      }
    case .assistant:
      assistantReply(message, showsProse: true)
    }
  }

  @ViewBuilder
  private func assistantReply(_ message: CaptureMessage, showsProse: Bool) -> some View {
    let owned = ownedDrafts(for: message)
    let saveIDs = owned.filter { !$0.committed && $0.included }.map(\.id)
    let accountClosed = session.usesClosedOrMissingAccount(ids: saveIDs, openAccounts: model.openAccounts)
    CaptureAssistantReply(
        message: message,
        drafts: owned,
        query: message.queryID.flatMap { id in session.queryCards.first { $0.id == id } },
        highlightID: highlightDraftID,
        showsProse: showsProse,
        accountName: accountName,
        categoryName: categoryName,
        amountText: amountText,
        dateText: dateText,
        money: { MoneyCodec.signedDisplayString(for: $0, currencyFormat: model.currencyFormat) },
        saveGroup: { saveGroup($0, owner: message.id) },
        toggleIncluded: { session.toggleIncluded($0) },
        edit: { item in
          guard !item.committed, !session.isBusy else { return }
          editingDraftID = item.id
        },
        remove: { session.removeDraft($0) },
        resolveAccount: { accountID, draftID in
          session.resolveAccount(accountID, forDraft: draftID)
        },
        resolveCategory: { categoryID, draftID in
          session.resolveCategory(categoryID, forDraft: draftID)
        },
        chooseUnresolvedAccount: { resolvingAccountDraftID = $0 },
        chooseUnresolvedCategory: { resolvingCategoryDraftID = $0 },
        chooseTarget: { id in
          session.chooseTargetDraft(id)
          persistCommittedCaptures(session.messages.last?.updatedDraftIDs ?? [])
        },
        inspectQuery: { inspectQueryCard = $0 },
        jumpToDraft: { id in
          highlightDraftID = id
          if let owner = session.ownerMessageID(forDraft: id) {
            jumpToMessage = owner
          }
        },
        retry: { retryReply(message.id) },
        enterManually: beginManualEntry,
        undo: session.canUndo(ownedIDs: message.ownedDraftIDs)
          ? {
            persistCommittedCaptures(session.undo())
          }
          : nil,
        pendingQuery: message.id == session.pendingQueryReplyID ? session.pendingQuery : nil,
        pendingTargetDrafts: message.id == session.pendingUpdateReplyID ? session.pendingTargetDrafts() : [],
        accountIsOpen: { draft in
          model.openAccounts.contains { $0.id == draft.accountID && !$0.deleted }
        },
        resolveQueryAccount: { candidate in
          resolvePendingQuery(account: candidate)
        },
        resolveQueryCategory: { candidate in
          resolvePendingQuery(category: candidate)
        },
        saveError: groupSaveErrors[message.id],
        canSave: session.canSaveGroup(ids: saveIDs) && !accountClosed,
        saveBlockedReason: accountClosed
          ? "Choose an open account"
          : session.groupSaveBlockReason(ids: saveIDs),
        isMutatingLocked: session.isBusy || session.isSaving,
        isSyncPending: { item in
          model.hasPendingCreate(importID: item.id)
        },
        canRetry: session.canRetry(message),
        intelligence: intelligence,
        activity: message.replyState == .generating ? session.aiActivity : nil
    )
  }

  private var intelligence: CaptureIntelligenceStatus {
    interpreter == nil ? model.captureAI.status : .available
  }

  private var plusMenu: some View {
    NavigationStack {
      List {
        Button("Photo Library") {
          isShowingPlus = false
          if CapturePasteAdmission.shouldRejectNewAttachments(session) {
            errorMessage = CapturePasteAdmission.inFlightMessage
            return
          }
          isShowingLibraryPicker = true
        }
        .disabled(session.isBusy || session.isIngesting)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("Camera") {
            isShowingPlus = false
            if CapturePasteAdmission.shouldRejectNewAttachments(session) {
              errorMessage = CapturePasteAdmission.inFlightMessage
              return
            }
            isShowingCamera = true
          }
          .disabled(session.isBusy || session.isIngesting)
        } else {
          Button("Camera unavailable") {
            isShowingPlus = false
            cameraUnavailableMessage = "This device has no camera. Use Photo Library or paste an image instead."
          }
        }
        PasteButton(
          supportedContentTypes: [
            .image,
            .jpeg,
            .png,
            .plainText,
            .utf8PlainText,
            .text,
          ]
        ) { providers in
          isShowingPlus = false
          if CapturePasteAdmission.shouldRejectNewAttachments(session) {
            errorMessage = CapturePasteAdmission.inFlightMessage
            return
          }
          ingest(itemProviders: providers)
        }
        .disabled(session.isBusy || session.isIngesting)
        .accessibilityHint("Pastes text or images from the clipboard. Content is only read after you tap Paste.")
      }
      .navigationTitle("Add")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { isShowingPlus = false }
            .tint(Theme.accent)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func revealLatest(_ proxy: ScrollViewProxy) {
    withAnimation {
      proxy.scrollTo("conversation-end", anchor: .bottom)
    }
  }

  private func ownedDrafts(for message: CaptureMessage) -> [CaptureDraftItem] {
    message.ownedDraftIDs.compactMap { id in
      session.drafts.first { $0.id == id }
    }
  }

  private var currentAccountName: String {
    if let id = session.selectedAccountID,
       let account = model.openAccounts.first(where: { $0.id == id }) {
      return account.name
    }
    return "Choose Account"
  }

  private var frozenLocalDate: String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = Calendar.current.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Calendar.current.startOfDay(for: Date()))
  }

  private func accountName(_ draft: TransactionDraft) -> String {
    model.openAccounts.first(where: { $0.id == draft.accountID })?.name
      ?? model.accounts.first(where: { $0.id == draft.accountID })?.name
      ?? "Choose Account"
  }

  private func categoryName(_ draft: TransactionDraft) -> String {
    if draft.isSplit {
      return "Split"
    }
    return model.categoryName(forID: draft.categoryID) ?? "Uncategorised"
  }

  private func amountText(_ draft: TransactionDraft) -> String {
    MoneyCodec.signedDisplayString(for: draft.signedMilliunits, currencyFormat: model.currencyFormat)
  }

  private func dateText(_ draft: TransactionDraft) -> String {
    if Calendar.current.isDateInToday(draft.date) {
      return "Today"
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: draft.date)
  }

  private func seededManualDraft() -> TransactionDraft {
    var draft = TransactionDraft()
    draft.seedIfNeeded(accounts: model.openAccounts, preferredAccountID: session.selectedAccountID)
    return draft
  }

  private func beginManualEntry() {
    guard !session.isSaving, isCurrent(capturedTurnScope()) else {
      return
    }
    isComposerFocused = false
    claimComposerFocus = false
    if session.isBusy {
      workspace.cancelOwnedConversationWork()
      session.stopActiveReply()
    }
    workspace.persistCurrentIfNeeded()
    creatingManual = true
  }

  private func capturedTurnScope(generation: Int? = nil) -> CaptureTurnScope {
    var scope = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: model.settings.viewPrefsScopeKey,
      workspace: workspace,
      planID: model.settings.planID
    )
    if let generation {
      scope.generation = generation
    }
    return scope
  }

  private func isCurrent(_ scope: CaptureTurnScope) -> Bool {
    scope.isCurrent(
      session: session,
      settingsScopeKey: model.settings.viewPrefsScopeKey,
      workspace: workspace,
      planID: model.settings.planID
    ) && workspace.current?.id == scope.sessionID
  }

  private func send() {
    guard session.canSendComposer, isCurrent(capturedTurnScope()) else {
      return
    }
    errorMessage = nil
    let frozen = session.freezeComposerTurn(accountName: currentAccountName, localDate: frozenLocalDate)
    jumpToMessage = frozen.userMessageID
    runFrozenTurn(frozen)
  }

  private func stopReply() {
    workspace.cancelOwnedConversationWork()
    session.stopActiveReply()
  }

  private func retryReply(_ replyID: UUID) {
    guard let frozen = session.prepareRetry(replyID: replyID) else {
      return
    }
    jumpToMessage = frozen.userMessageID
    runFrozenTurn(frozen)
  }

  private func runFrozenTurn(_ frozen: CaptureFrozenTurn) {
    guard isCurrent(capturedTurnScope()) else {
      return
    }
    let selectedInterpreter: CaptureInterpreter
    let provider: String
    do {
      if let interpreter {
        selectedInterpreter = interpreter
        provider = "On-device model"
      } else if let configuration = try model.captureAI.configuration() {
        selectedInterpreter = CaptureInterpreter(backend: .remote(configuration))
        provider = "\(configuration.providerName) · \(configuration.model.name)"
      } else {
        selectedInterpreter = .shared
        provider = "On-device model"
      }
    } catch {
      session.recordFailedTurn(error.localizedDescription)
      workspace.persistCurrentIfNeeded()
      return
    }
    let token = session.beginTurn(provider: provider)
    let turnScope = capturedTurnScope(generation: token.generation)
    let client = model.apiClient
    let accounts = model.openAccounts
    let categories = model.categoryGroups
    let payees = model.payees
    let context = CaptureInterpreterPrompt.context(
      text: frozen.text,
      session: session,
      accounts: accounts,
      categoryGroups: categories,
      attachmentIDs: frozen.attachmentIDs,
      frozen: frozen
    )
    workspace.runConversationTurn {
      let result = await selectedInterpreter.interpret(
        context: context,
        accounts: accounts,
        categoryGroups: categories,
        payees: payees,
        conversationID: self.session.id,
        progress: { [session = self.session] phase in
          await session.updateAIPhase(phase, generation: token.generation)
        }
      )
      defer {
        _ = self.session.finishTurn(generation: token.generation)
        if self.isCurrent(turnScope) {
          self.workspace.persistCurrentIfNeeded()
        }
      }
      guard !Task.isCancelled else {
        return
      }
      guard self.isCurrent(turnScope), self.session.matchesTurn(generation: token.generation) else {
        return
      }
      switch result {
      case .success(let value):
        await self.applyTurn(
          value.0,
          changes: value.1,
          expectedRevision: token.revision,
          expectedGeneration: token.generation,
          turnScope: turnScope,
          client: client
        )
      case .failure(let error):
        guard self.isCurrent(turnScope), self.session.matchesTurn(generation: token.generation) else {
          return
        }
        self.session.recordFailedTurn(error.localizedDescription)
      }
    }
  }

  private func applyTurn(
    _ turn: CaptureInterpretedTurn,
    changes: [CaptureMappedChange],
    expectedRevision: Int,
    expectedGeneration: Int,
    turnScope: CaptureTurnScope,
    client: APIClient
  ) async {
    guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
      return
    }
    if turn.intent == .query {
      session.updateAIPhase(.fetching, generation: expectedGeneration)
      await runQuery(turn.query, turnScope: turnScope, client: client, expectedGeneration: expectedGeneration)
      return
    }
    if turn.intent == .add || turn.intent == .update, changes.isEmpty, turn.feedback.isEmpty {
      if CapturePayeeRename.payee(from: session.frozenTurn?.text ?? "") == nil {
        session.recordFailedTurn("I could not read a spend in that. Your drafts are still here.")
        return
      }
    }
    _ = session.apply(
      turn: turn,
      changes: changes,
      expectedRevision: expectedRevision,
      expectedGeneration: expectedGeneration
    )
    persistCommittedCaptures(session.messages.last?.updatedDraftIDs ?? [])
  }

  private func persistCommittedCaptures(_ ids: [String]) {
    guard !ids.isEmpty else {
      return
    }
    for item in session.drafts where item.committed && ids.contains(item.id) {
      model.reviseConversationCapture(item)
    }
  }

  private func runQuery(
    _ spec: LedgerQuerySpec?,
    turnScope: CaptureTurnScope,
    client: APIClient,
    expectedGeneration: Int
  ) async {
    guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
      return
    }
    guard let spec else {
      session.recordFailedTurn("I can answer recorded spending questions, but I need a clearer request.")
      return
    }
    let queryNow = session.frozenTurn.flatMap {
      SlipReaderMapping.date(from: $0.localDate, calendar: .current, now: .now)
    } ?? Date()
    switch LedgerQueryPlanner.resolve(
      spec: spec,
      accounts: model.accounts,
      categoryGroups: model.categoryGroups,
      now: queryNow
    ) {
    case .failure(let error):
      session.pendingQuery = nil
      session.pendingQueryReplyID = nil
      session.recordFailedTurn(error.localizedDescription)
    case .success(let resolution):
      await fulfilResolution(resolution, turnScope: turnScope, client: client, expectedGeneration: expectedGeneration)
    }
  }

  private func fulfilResolution(
    _ resolution: LedgerQueryResolution,
    turnScope: CaptureTurnScope,
    client: APIClient,
    expectedGeneration: Int
  ) async {
    guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
      return
    }
    if let error = LedgerQueryPlanner.capabilityError(for: resolution.spec) {
      session.pendingQuery = nil
      session.pendingQueryReplyID = nil
      session.recordFailedTurn(error.localizedDescription)
      return
    }
    if !resolution.unresolvedAccount.isEmpty || !resolution.unresolvedCategory.isEmpty {
      session.pendingQuery = resolution
      session.pendingQueryReplyID = session.frozenTurn?.replyMessageID
      session.recordFailedTurn("Which account or category did you mean? I will not guess.")
      return
    }
    session.pendingQuery = nil
    session.pendingQueryReplyID = nil
    do {
      let card = try await loadQueryCard(
        resolution,
        turnScope: turnScope,
        client: client,
        expectedGeneration: expectedGeneration
      )
      guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
        return
      }
      session.queryCards.append(card)
      session.finishReply(text: card.detail, queryID: card.id, replyID: session.frozenTurn?.replyMessageID)
    } catch is CancellationError {
      return
    } catch {
      guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
        return
      }
      session.recordFailedTurn("I could not load recorded spending. \(error.localizedDescription)")
    }
  }

  private func resolvePendingQuery(account: SlipCandidate? = nil, category: SlipCandidate? = nil) {
    guard !session.isBusy, isCurrent(capturedTurnScope()), let pending = session.pendingQuery else {
      return
    }
    let token = session.beginTurn()
    let turnScope = capturedTurnScope(generation: token.generation)
    let client = model.apiClient
    let resolved = LedgerQueryPlanner.applyingChosenIdentities(
      to: pending,
      account: account,
      category: category
    )
    if let owner = session.pendingQueryReplyID {
      session.frozenTurn = session.messages.first { $0.id == owner }?.frozenTurn
      session.finishReply(text: "", state: .generating, replyID: owner)
    }
    session.pendingQuery = nil
    session.pendingQueryReplyID = nil
    session.updateAIPhase(.fetching, generation: token.generation)
    workspace.runConversationTurn {
      defer {
        _ = self.session.finishTurn(generation: token.generation)
        if self.isCurrent(turnScope) {
          self.workspace.persistCurrentIfNeeded()
        }
      }
      guard !Task.isCancelled else {
        return
      }
      guard self.isCurrent(turnScope), self.session.matchesTurn(generation: token.generation) else {
        return
      }
      await self.fulfilResolution(resolved, turnScope: turnScope, client: client, expectedGeneration: token.generation)
    }
  }

  private func loadQueryCard(
    _ resolution: LedgerQueryResolution,
    turnScope: CaptureTurnScope,
    client: APIClient,
    expectedGeneration: Int
  ) async throws -> LedgerQueryResult {
    func stillCurrent() -> Bool {
      isCurrent(turnScope) && session.matchesTurn(generation: expectedGeneration)
    }
    guard stillCurrent() else {
      throw CancellationError()
    }
    switch resolution.spec.kind {
    case .findMerchant:
      let rows = try await LedgerQueryRunner.fetchAllTransactions(
        client: client,
        planID: turnScope.planID,
        accountID: resolution.accountIDs.first,
        sinceDate: resolution.from,
        untilDate: resolution.to,
        isCancelled: { !stillCurrent() }
      )
      guard stillCurrent() else {
        throw CancellationError()
      }
      let sourceAll = LedgerQueryPlanner.sourceRows(
        from: rows,
        resolution: resolution,
        categoryGroups: model.categoryGroups,
        includeQuiet: model.includeQuietSpending || resolution.categoryWasExplicit,
        merchant: resolution.spec.merchant
      )
      let total = sourceAll.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
      return LedgerQueryResult(
        title: "Payments to \(resolution.spec.merchant)",
        detail: "\(sourceAll.count) recorded payments from \(resolution.from) to \(resolution.to) · \(resolution.accountLabel)",
        totalMilliunits: total,
        from: resolution.from,
        to: resolution.to,
        accountLabel: resolution.accountLabel,
        categoryLabel: resolution.categoryLabel,
        sourceRows: sourceAll,
        sourceCount: sourceAll.count,
        isPreview: false,
        isRecordedSpending: true,
        isUnavailable: false
      )
    case .spendingThisMonth, .spending, .today, .compareCategory:
      let report = try await client.fetchSpendingBreakdown(
        planID: turnScope.planID,
        from: resolution.from,
        to: resolution.to,
        accountIDs: resolution.accountIDs,
        categoryIDs: resolution.categoryIDs
      )
      guard stillCurrent() else {
        throw CancellationError()
      }
      let total = LedgerQueryPlanner.recordedSpendingTotal(
        from: report,
        includeQuiet: model.includeQuietSpending || resolution.categoryWasExplicit,
        explicitCategoryIDs: resolution.categoryIDs
      )
      var comparison: Int?
      if let priorFrom = resolution.priorFrom, let priorTo = resolution.priorTo {
        let prior = try await client.fetchSpendingBreakdown(
          planID: turnScope.planID,
          from: priorFrom,
          to: priorTo,
          accountIDs: resolution.accountIDs,
          categoryIDs: resolution.categoryIDs
        )
        comparison = LedgerQueryPlanner.recordedSpendingTotal(
          from: prior,
          includeQuiet: model.includeQuietSpending || resolution.categoryWasExplicit,
          explicitCategoryIDs: resolution.categoryIDs
        )
        guard stillCurrent() else {
          throw CancellationError()
        }
      }
      let money = MoneyCodec.displayString(for: -total, currencyFormat: model.currencyFormat)
      let comparisonText: String
      if let comparison, let priorFrom = resolution.priorFrom, let priorTo = resolution.priorTo {
        comparisonText = " vs \(MoneyCodec.displayString(for: -comparison, currencyFormat: model.currencyFormat)) \(priorFrom) to \(priorTo)"
      } else {
        comparisonText = ""
      }
      let source = await loadSourceRows(
        resolution,
        turnScope: turnScope,
        client: client,
        expectedGeneration: expectedGeneration
      )
      guard stillCurrent() else {
        throw CancellationError()
      }
      let title: String
      switch resolution.spec.kind {
      case .today:
        title = "Today"
      case .compareCategory:
        title = resolution.categoryLabel
      default:
        title = "Recorded spending"
      }
      return LedgerQueryResult(
        title: title,
        detail: "\(money) recorded spending from \(resolution.from) to \(resolution.to) · \(resolution.accountLabel)\(comparisonText)",
        totalMilliunits: total,
        comparisonMilliunits: comparison,
        from: resolution.from,
        to: resolution.to,
        comparisonFrom: resolution.priorFrom,
        comparisonTo: resolution.priorTo,
        accountLabel: resolution.accountLabel,
        categoryLabel: resolution.categoryLabel,
        sourceRows: source,
        sourceCount: source.count,
        isPreview: false,
        isRecordedSpending: true,
        isUnavailable: false
      )
    case .unsupported:
      throw CaptureInterpreterError.model("That question is not supported.")
    }
  }

  private func loadSourceRows(
    _ resolution: LedgerQueryResolution,
    turnScope: CaptureTurnScope,
    client: APIClient,
    expectedGeneration: Int
  ) async -> [LedgerQuerySourceRow] {
    do {
      let rows = try await LedgerQueryRunner.fetchAllTransactions(
        client: client,
        planID: turnScope.planID,
        accountID: resolution.accountIDs.first,
        sinceDate: resolution.from,
        untilDate: resolution.to,
        isCancelled: {
          !isCurrent(turnScope) || !session.matchesTurn(generation: expectedGeneration)
        }
      )
      guard isCurrent(turnScope), session.matchesTurn(generation: expectedGeneration) else {
        return []
      }
      return LedgerQueryPlanner.sourceRows(
        from: rows,
        resolution: resolution,
        categoryGroups: model.categoryGroups,
        includeQuiet: model.includeQuietSpending || resolution.categoryWasExplicit,
        merchant: resolution.spec.merchant
      )
    } catch {
      return []
    }
  }

  private func saveGroup(_ ids: [String], owner: UUID) {
    let scope = capturedTurnScope()
    guard isCurrent(scope) else {
      return
    }
    let items = session.groupSaveCandidates(ids: ids)
    if session.usesClosedOrMissingAccount(ids: ids, openAccounts: model.openAccounts) {
      groupSaveErrors[owner] = "Choose an open account"
      return
    }
    guard session.canSaveGroup(ids: ids) else {
      groupSaveErrors[owner] = session.groupSaveBlockReason(ids: ids)
        ?? "Enter an amount and pick an account."
      return
    }
    session.isSaving = true
    defer { session.isSaving = false }
    guard isCurrent(scope) else {
      return
    }
    do {
      try model.commit(items.map(\.draft))
      session.markCommitted(ids: items.map(\.id))
      workspace.persistCurrentIfNeeded()
      groupSaveErrors[owner] = nil
    } catch {
      groupSaveErrors[owner] = error.localizedDescription
    }
  }

  private func beginIngest(pickerItems: [PhotosPickerItem]) {
    guard !pickerItems.isEmpty else {
      return
    }
    let turnScope = capturedTurnScope()
    guard isCurrent(turnScope) else {
      photoItems = []
      return
    }
    if CapturePasteAdmission.shouldRejectNewAttachments(session) {
      errorMessage = CapturePasteAdmission.inFlightMessage
      photoItems = []
      return
    }
    session.isTransferringImages = true
    photoItems = []
    Task { @MainActor in
      await ingestAdmitted(pickerItems: pickerItems, turnScope: turnScope)
    }
  }

  private func beginIngest(images: [UIImage], filenamePrefix: String) {
    guard !images.isEmpty else {
      return
    }
    let turnScope = capturedTurnScope()
    guard isCurrent(turnScope) else {
      return
    }
    if CapturePasteAdmission.shouldRejectNewAttachments(session) {
      errorMessage = CapturePasteAdmission.inFlightMessage
      return
    }
    session.isTransferringImages = true
    Task { @MainActor in
      await ingestAdmitted(images: images, filenamePrefix: filenamePrefix, turnScope: turnScope)
    }
  }

  private func ingest(itemProviders: [NSItemProvider]) {
    guard !itemProviders.isEmpty else {
      return
    }
    let turnScope = capturedTurnScope()
    guard isCurrent(turnScope) else {
      return
    }
    let offersImages = itemProviders.contains(where: CapturePasteAdmission.offersImage)
    if offersImages && CapturePasteAdmission.shouldRejectNewAttachments(session) {
      errorMessage = CapturePasteAdmission.inFlightMessage
      Task { @MainActor in
        await applyPastedText(
          from: itemProviders,
          turnScope: turnScope,
          failures: [CapturePasteAdmission.inFlightMessage]
        )
      }
      return
    }
    let beganTransfer = !session.isTransferringImages
    if beganTransfer {
      session.isTransferringImages = true
    }
    Task { @MainActor in
      await ingestAdmitted(itemProviders: itemProviders, beganTransfer: beganTransfer, turnScope: turnScope)
    }
  }

  private func ingestAdmitted(pickerItems: [PhotosPickerItem], turnScope: CaptureTurnScope) async {
    defer {
      session.isTransferringImages = false
      if isCurrent(turnScope) {
        workspace.persistCurrentIfNeeded()
      }
    }
    for (index, item) in pickerItems.enumerated() {
      guard isCurrent(turnScope) else {
        return
      }
      var attachment = CaptureAttachment(
        filename: "photo-\(index + 1).jpg",
        data: Data(),
        isReading: true
      )
      session.addAttachment(attachment)
      do {
        let data = try await item.loadTransferable(type: Data.self)
        guard isCurrent(turnScope) else {
          return
        }
        guard let data, let image = UIImage(data: data) else {
          attachment.isReading = false
          attachment.errorMessage = "I could not load that photo. It was not attached."
          session.updateAttachment(attachment)
          errorMessage = attachment.errorMessage
          continue
        }
        await ingest(image: image, into: &attachment, turnScope: turnScope)
      } catch {
        guard isCurrent(turnScope) else {
          return
        }
        attachment.isReading = false
        attachment.errorMessage = "I could not load that photo. It was not attached."
        session.updateAttachment(attachment)
        errorMessage = attachment.errorMessage
      }
    }
  }

  private func ingestAdmitted(images: [UIImage], filenamePrefix: String, turnScope: CaptureTurnScope) async {
    defer {
      session.isTransferringImages = false
      if isCurrent(turnScope) {
        workspace.persistCurrentIfNeeded()
      }
    }
    for (index, image) in images.enumerated() {
      guard isCurrent(turnScope) else {
        return
      }
      var attachment = CaptureAttachment(
        filename: "\(filenamePrefix)-\(index + 1).jpg",
        data: Data(),
        isReading: true
      )
      session.addAttachment(attachment)
      await ingest(image: image, into: &attachment, turnScope: turnScope)
    }
  }

  private func ingestAdmitted(
    itemProviders: [NSItemProvider],
    beganTransfer: Bool,
    turnScope: CaptureTurnScope
  ) async {
    var failures: [String] = []
    defer {
      if beganTransfer {
        session.isTransferringImages = false
      }
      if isCurrent(turnScope) {
        if !failures.isEmpty {
          errorMessage = failures.joined(separator: " ")
        }
        workspace.persistCurrentIfNeeded()
      }
    }
    for (index, provider) in itemProviders.enumerated() {
      guard isCurrent(turnScope) else {
        return
      }
      let offersImage = CapturePasteAdmission.offersImage(provider)
      let offersText = CapturePasteAdmission.offersText(provider)
      if offersImage {
        do {
          let image = try await loadPastedImage(from: provider)
          guard isCurrent(turnScope) else {
            return
          }
          var attachment = CaptureAttachment(
            filename: "paste-\(index + 1).jpg",
            data: Data(),
            isReading: true
          )
          session.addAttachment(attachment)
          await ingest(image: image, into: &attachment, turnScope: turnScope)
        } catch {
          guard isCurrent(turnScope) else {
            return
          }
          failures.append("I could not load a pasted image. It was not attached.")
        }
      }
      if offersText {
        do {
          let text = try await loadPastedText(from: provider)
          guard isCurrent(turnScope) else {
            return
          }
          appendComposerText(text)
        } catch {
          guard isCurrent(turnScope) else {
            return
          }
          failures.append("I could not load the pasted text.")
        }
      }
      if !offersImage && !offersText {
        failures.append("That clipboard item is not text or an image.")
      }
    }
  }

  private func applyPastedText(
    from itemProviders: [NSItemProvider],
    turnScope: CaptureTurnScope,
    failures: [String]
  ) async {
    var failures = failures
    for provider in itemProviders where CapturePasteAdmission.offersText(provider) {
      guard isCurrent(turnScope) else {
        return
      }
      do {
        let text = try await loadPastedText(from: provider)
        guard isCurrent(turnScope) else {
          return
        }
        appendComposerText(text)
      } catch {
        guard isCurrent(turnScope) else {
          return
        }
        failures.append("I could not load the pasted text.")
      }
    }
    if isCurrent(turnScope), !failures.isEmpty {
      errorMessage = failures.joined(separator: " ")
    }
  }

  private func appendComposerText(_ pasted: String) {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }
    if !session.composerText.isEmpty {
      session.composerText += " "
    }
    session.composerText += trimmed
  }

  private func loadPastedImage(from provider: NSItemProvider) async throws -> UIImage {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadObject(ofClass: UIImage.self) { object, error in
        if let image = object as? UIImage {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? CapturePasteLoadError.imageUnavailable)
        }
      }
    }
  }

  private func loadPastedText(from provider: NSItemProvider) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadObject(ofClass: NSString.self) { object, error in
        if let text = object as? String {
          continuation.resume(returning: text)
        } else if let text = object as? NSString {
          continuation.resume(returning: text as String)
        } else {
          continuation.resume(throwing: error ?? CapturePasteLoadError.textUnavailable)
        }
      }
    }
  }

  private func ingest(image: UIImage, into attachment: inout CaptureAttachment, turnScope: CaptureTurnScope) async {
    guard isCurrent(turnScope) else {
      return
    }
    guard let data = image.jpegData(compressionQuality: 0.8) else {
      attachment.isReading = false
      attachment.errorMessage = "I could not keep that image on this device."
      session.updateAttachment(attachment)
      return
    }
    guard data.count <= InboxStore.maxPayloadBytes else {
      attachment.isReading = false
      attachment.errorMessage = "That image is too large to keep on this device."
      session.updateAttachment(attachment)
      return
    }
    attachment.data = data
    attachment.isReading = true
    attachment.errorMessage = nil
    session.updateAttachment(attachment)
    let text = await SlipImageText.recognize(data)
    applyOCRCompletion(text, attachmentID: attachment.id, turnScope: turnScope)
  }

  private func retryReadingImage(_ id: UUID) {
    let turnScope = capturedTurnScope()
    guard isCurrent(turnScope), !session.isBusy, !session.isSaving, !session.isIngesting else {
      return
    }
    guard var attachment = session.attachments.first(where: { $0.id == id }) else {
      return
    }
    if attachment.data.isEmpty || UIImage(data: attachment.data) == nil {
      attachment.isReading = false
      attachment.errorMessage = attachment.data.isEmpty
        ? "I could not keep that image on this device."
        : "I could not read text from that image. It is still attached."
      session.updateAttachment(attachment)
      workspace.persistCurrentIfNeeded()
      return
    }
    attachment.isReading = true
    attachment.errorMessage = nil
    session.updateAttachment(attachment)
    workspace.persistCurrentIfNeeded()
    let bytes = attachment.data
    Task { @MainActor in
      let text = await SlipImageText.recognize(bytes)
      self.applyOCRCompletion(text, attachmentID: id, turnScope: turnScope)
    }
  }

  private func applyOCRCompletion(_ text: String, attachmentID: UUID, turnScope: CaptureTurnScope) {
    guard session.id == turnScope.sessionID else {
      return
    }
    guard var attachment = session.attachments.first(where: { $0.id == attachmentID }) else {
      return
    }
    attachment.isReading = false
    if isCurrent(turnScope) {
      attachment.recognizedText = text
      attachment.errorMessage = text.isEmpty
        ? "I could not read text from that image. It is still attached."
        : nil
      session.updateAttachment(attachment)
      workspace.persistCurrentIfNeeded()
      return
    }
    if attachment.errorMessage?.isEmpty != false {
      attachment.errorMessage = "I could not read text from that image. It is still attached."
    }
    session.updateAttachment(attachment)
  }

}

enum CapturePasteAdmission {
  static let inFlightMessage = "Still attaching the previous photo or paste. Wait until that finishes, then try again."

  static func offersImage(_ provider: NSItemProvider) -> Bool {
    provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
      || provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier)
      || provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
  }

  static func offersText(_ provider: NSItemProvider) -> Bool {
    provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
      || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
  }

  @MainActor
  static func shouldRejectNewAttachments(_ session: CaptureSession) -> Bool {
    session.isIngesting || session.isBusy || session.isSaving
  }
}

private enum CapturePasteLoadError: Error {
  case imageUnavailable
  case textUnavailable
}

enum CaptureComposerMetrics {
  static let minHeight: CGFloat = 44
  static let maxHeight: CGFloat = 120
  static let horizontalInset: CGFloat = 4

  static func bodyFont() -> UIFont {
    UIFont.preferredFont(forTextStyle: .body)
  }

  static func textContainerInset(for font: UIFont) -> UIEdgeInsets {
    let vertical = max(8, ((minHeight - font.lineHeight) / 2).rounded())
    return UIEdgeInsets(top: vertical, left: horizontalInset, bottom: vertical, right: horizontalInset)
  }

  static func fittedHeight(usedRectHeight: CGFloat, font: UIFont, inset: UIEdgeInsets) -> CGFloat {
    let line = max(font.lineHeight, 1)
    let content = max(usedRectHeight, line) + inset.top + inset.bottom
    return min(max(content.rounded(.up), minHeight), maxHeight)
  }
}

struct CaptureComposerField: UIViewRepresentable {
  @Binding var text: String
  @Binding var isComposerFocused: Bool
  var claimFocus: Bool = false
  var onImages: ([UIImage]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isComposerFocused: $isComposerFocused, onImages: onImages)
  }

  func makeUIView(context: Context) -> UITextView {
    let view = PasteAwareTextView()
    view.delegate = context.coordinator
    view.onPasteImages = { images in
      context.coordinator.onImages(images)
    }
    let font = CaptureComposerMetrics.bodyFont()
    view.font = font
    view.backgroundColor = .clear
    view.textContainer.lineFragmentPadding = 0
    view.textContainerInset = CaptureComposerMetrics.textContainerInset(for: font)
    view.adjustsFontForContentSizeCategory = true
    view.keyboardDismissMode = .interactive
    return view
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    context.coordinator.text = $text
    context.coordinator.isComposerFocused = $isComposerFocused
    context.coordinator.onImages = onImages
    applyComposerChrome(uiView)
    if uiView.text != text {
      let selected = uiView.selectedRange
      uiView.text = text
      if selected.location <= (uiView.text as NSString?)?.length ?? 0 {
        uiView.selectedRange = selected
      }
    }
    if let pasteView = uiView as? PasteAwareTextView {
      pasteView.placeholder = text.isEmpty ? "Message…" : nil
      pasteView.onPasteImages = { images in
        context.coordinator.onImages(images)
      }
      pasteView.alignTextToVerticalCenterIfNeeded()
    }
    if claimFocus, !uiView.isFirstResponder {
      _ = uiView.becomeFirstResponder()
    }
    if !isComposerFocused, !claimFocus, uiView.isFirstResponder {
      uiView.resignFirstResponder()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    guard width > 0 else {
      return CGSize(width: 0, height: CaptureComposerMetrics.minHeight)
    }
    applyComposerChrome(uiView)
    let font = uiView.font ?? CaptureComposerMetrics.bodyFont()
    uiView.textContainer.size = CGSize(
      width: max(0, width - uiView.textContainerInset.left - uiView.textContainerInset.right),
      height: .greatestFiniteMagnitude
    )
    uiView.layoutManager.ensureLayout(for: uiView.textContainer)
    let used = uiView.layoutManager.usedRect(for: uiView.textContainer).height
    return CGSize(
      width: width,
      height: CaptureComposerMetrics.fittedHeight(
        usedRectHeight: used,
        font: font,
        inset: uiView.textContainerInset
      )
    )
  }

  private func applyComposerChrome(_ uiView: UITextView) {
    let font = uiView.font ?? CaptureComposerMetrics.bodyFont()
    uiView.textContainer.lineFragmentPadding = 0
    let inset = CaptureComposerMetrics.textContainerInset(for: font)
    if uiView.textContainerInset != inset {
      uiView.textContainerInset = inset
    }
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var text: Binding<String>
    var isComposerFocused: Binding<Bool>
    var onImages: ([UIImage]) -> Void

    init(text: Binding<String>, isComposerFocused: Binding<Bool>, onImages: @escaping ([UIImage]) -> Void) {
      self.text = text
      self.isComposerFocused = isComposerFocused
      self.onImages = onImages
    }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text ?? ""
      (textView as? PasteAwareTextView)?.alignTextToVerticalCenterIfNeeded()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      isComposerFocused.wrappedValue = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      isComposerFocused.wrappedValue = false
    }
  }
}

struct QuerySourceListView: View {
  let card: LedgerQueryResult
  let currencyFormat: CurrencyFormat?

  private var sourceSectionTitle: String {
    let splits = card.sourceRows.filter(\.isSplitPortion).count
    if splits == 0 {
      return "\(card.sourceCount) payments"
    }
    return "\(card.sourceCount) payments, \(splits) split portions"
  }

  private func sourceRowFootnote(_ row: LedgerQuerySourceRow) -> String {
    let split = row.isSplitPortion ? " · Split portion" : ""
    return "\(row.date) · \(row.accountName) · \(row.categoryName)\(split)"
  }

  var body: some View {
    List {
      Section {
        Text(card.detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
        if card.isRecordedSpending {
          Text("Recorded spending · \(card.from) to \(card.to)")
            .font(.caption)
            .foregroundStyle(Theme.uncategorised)
        }
      }
      Section(sourceSectionTitle) {
        ForEach(card.sourceRows) { row in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(row.payee)
                .font(.body.weight(.semibold))
              Text(sourceRowFootnote(row))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyCodec.signedDisplayString(for: row.amount, currencyFormat: currencyFormat))
              .font(.subheadline.weight(.medium))
              .monospacedDigit()
              .foregroundStyle(Theme.registerAmountColour(row.amount))
          }
        }
      }
    }
    .navigationTitle(card.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

final class PasteAwareTextView: UITextView {
  var onPasteImages: (([UIImage]) -> Void)?
  var placeholder: String? {
    didSet { setNeedsDisplay() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    alignTextToVerticalCenterIfNeeded()
  }

  func alignTextToVerticalCenterIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }
    let font = font ?? CaptureComposerMetrics.bodyFont()
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer).height
    let contentHeight = max(used, font.lineHeight) + textContainerInset.top + textContainerInset.bottom
    let slack = max(0, bounds.height - contentHeight)
    let top = (slack / 2).rounded()
    let inset = UIEdgeInsets(top: top, left: 0, bottom: slack - top, right: 0)
    if contentInset != inset {
      contentInset = inset
      setNeedsDisplay()
    }
    if slack > 0 {
      if abs(contentOffset.y + top) > 0.5 {
        contentOffset = CGPoint(x: 0, y: -top)
      }
    } else if contentOffset.y < -0.5 {
      contentOffset = .zero
    }
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let placeholder, text.isEmpty else {
      return
    }
    let drawingFont = font ?? CaptureComposerMetrics.bodyFont()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: drawingFont,
      .foregroundColor: UIColor.secondaryLabel,
    ]
    let dx = textContainerInset.left + textContainer.lineFragmentPadding
    let dy = textContainerInset.top + contentInset.top
    let drawRect = CGRect(
      x: rect.minX + dx,
      y: rect.minY + dy,
      width: max(0, rect.width - dx - textContainerInset.right - textContainer.lineFragmentPadding),
      height: drawingFont.lineHeight
    )
    placeholder.draw(in: drawRect, withAttributes: attrs)
  }

  override func paste(_ sender: Any?) {
    let board = UIPasteboard.general
    if board.hasImages, let images = board.images, !images.isEmpty {
      onPasteImages?(images)
    }
    if board.hasStrings {
      super.paste(sender)
    }
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
      return true
    }
    return super.canPerformAction(action, withSender: sender)
  }
}

struct CaptureNamePickList: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let names: [(id: String, name: String)]
  let onPick: (String) -> Void

  var body: some View {
    List(names, id: \.id) { row in
      Button(row.name) {
        onPick(row.id)
        dismiss()
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct CameraPicker: UIViewControllerRepresentable {
  var onImage: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator {
    Coordinator(onImage: onImage, dismiss: dismiss)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onImage: (UIImage) -> Void
    let dismiss: DismissAction

    init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
      self.onImage = onImage
      self.dismiss = dismiss
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      dismiss()
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        onImage(image)
      }
      dismiss()
    }
  }
}
