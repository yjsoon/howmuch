import SwiftUI

struct AssistantView: View {
  @Environment(AppModel.self) private var model
  var workspace: CaptureWorkspace
  @State private var brief: LedgerQueryResult?
  @State private var briefError: String?
  @State private var isLoadingBrief = false
  @State private var briefScopeKey: String?
  @State private var pendingDiscardID: UUID?
  @State private var isConfirmingClear = false
  @State private var briefDay: String?
  @State private var briefGeneration = 0
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var workspace = workspace
    home
    .background(Theme.canvas)
    .navigationTitle("Assistant")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DestinationsMenu(omitting: .assistant)
      }
    }
    .navigationDestination(isPresented: Binding(
      get: { workspace.pendingAssistantSessionID != nil },
      set: { presented in
        if !presented {
          workspace.pendingAssistantSessionID = nil
        }
      }
    )) {
      if let session = workspace.current {
        AddTransactionsView(session: session, embeddedInAssistant: true, workspace: workspace)
          .toolbar(.hidden, for: .tabBar)
      }
    }
    .task(id: AssistantBriefRefreshKey(
      scope: model.settings.viewPrefsScopeKey,
      reportsGeneration: model.reportsRefreshGeneration
    )) {
      workspace.activate(scopeKey: model.settings.viewPrefsScopeKey)
      await loadBrief()
    }
    .onChange(of: workspace.pendingAssistantSessionID) { _, id in
      if let id {
        _ = workspace.resume(id)
      } else {
        Task { await loadBrief() }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { @MainActor in
          if isLoadingBrief {
            return
          }
          await loadBrief()
        }
      }
    }
    .binaryConfirm(
      "Discard this conversation?",
      isPresented: Binding(
        get: { pendingDiscardID != nil },
        set: { if !$0 { pendingDiscardID = nil } }
      ),
      confirm: .destructive("Discard")
    ) {
      if let pendingDiscardID {
        workspace.discard(id: pendingDiscardID)
      }
      pendingDiscardID = nil
    }
    .binaryConfirm(
      "Clear conversation history?",
      isPresented: $isConfirmingClear,
      confirm: .destructive("Clear history")
    ) {
      workspace.discardAll()
    }
  }

  private var home: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        todayCard
        Button {
          startNewConversation()
        } label: {
          Label("New conversation", systemImage: "plus.message")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)

        if !workspace.recents.isEmpty {
          Text("Recent")
            .font(.headline)
          ForEach(workspace.recents, id: \.id) { snapshot in
            recentRow(snapshot)
          }
          Button("Clear history", role: .destructive) {
            isConfirmingClear = true
          }
          .font(.footnote.weight(.semibold))
        }
      }
      .padding(16)
      .animation(Theme.Motion.standard, value: workspace.recents.map(\.id))
    }
  }

  private var todayCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Today")
        .font(.headline)
      // A refresh keeps the last brief on screen rather than flashing the
      // loading line every time the Assistant reappears.
      if isLoadingBrief, brief == nil {
        Text("Loading recorded spending…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let briefError {
        Text(briefError)
          .font(.subheadline)
          .foregroundStyle(Theme.uncategorised)
      } else if let brief {
        Text(brief.detail)
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        Text("\(brief.from) – \(brief.to) · \(brief.accountLabel)")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if brief.isRecordedSpending {
          Text("Recorded spending")
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.uncategorised)
        }
        if !brief.sourceRows.isEmpty {
          NavigationLink {
            QuerySourceListView(card: brief, currencyFormat: model.currencyFormat)
          } label: {
            Text(brief.sourceCount == 1
              ? "Inspect 1 matching payment"
              : "Inspect \(brief.sourceCount) matching payments")
              .font(.footnote.weight(.semibold))
          }
        }
      } else {
        Text("No recorded-spending brief yet.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .ynabCard()
  }

  private func recentRow(_ snapshot: CaptureSessionSnapshot) -> some View {
    HStack {
      Button {
        _ = workspace.resume(snapshot.id)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(recentTitle(snapshot))
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2)
          Text(recentSubtitle(snapshot))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      Button {
        pendingDiscardID = snapshot.id
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(Theme.outflow)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Discard this conversation")
    }
    .padding(.leading, 16)
    .padding(.trailing, 4)
    .padding(.vertical, 8)
    .ynabCard()
  }

  private func startNewConversation() {
    let session = workspace.admit(
      request: CaptureRequest(
        kind: .blank,
        connectionFingerprint: model.settings.connectionFingerprint,
        origin: .lastUsedOpen
      ),
      scopeKey: model.settings.viewPrefsScopeKey,
      openAccounts: model.openAccounts,
      lastUsedAccountID: model.lastUsedOpenAccountID,
      focusedRegisterAccountID: nil
    )
    workspace.pendingAssistantSessionID = session.id
  }

  private func recentTitle(_ snapshot: CaptureSessionSnapshot) -> String {
    if let text = snapshot.messages.last(where: { $0.kind == .user })?.text, !text.isEmpty {
      return text
    }
    if !snapshot.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !snapshot.attachmentRecords.isEmpty
      || !(snapshot.pendingAttachmentIDs ?? []).isEmpty {
      return "Message draft"
    }
    return snapshot.titleFallback
  }

  private func recentSubtitle(_ snapshot: CaptureSessionSnapshot) -> String {
    if snapshot.unsavedDraftCount == 0 {
      return "Conversation"
    }
    return snapshot.unsavedDraftCount == 1
      ? "1 unsaved transaction"
      : "\(snapshot.unsavedDraftCount) unsaved transactions"
  }

  private func loadBrief() async {
    briefGeneration += 1
    let generation = briefGeneration
    let client = model.apiClient
    let settingsScope = model.settings.viewPrefsScopeKey
    let workspaceScope = workspace.activeScopeKey
    let planID = model.settings.planID
    // A refresh keeps the last brief visible, but never one from another
    // plan, scope or day (yesterday's "today" figure must not linger).
    let scopeKey = "\(planID)|\(settingsScope ?? "")|\(workspaceScope ?? "")|\(Date.now.isoDateString)"
    if briefScopeKey != scopeKey {
      brief = nil
      briefError = nil
      briefScopeKey = scopeKey
    }
    isLoadingBrief = true
    func stillCurrent() -> Bool {
      generation == briefGeneration
        && model.settings.viewPrefsScopeKey == settingsScope
        && workspace.activeScopeKey == workspaceScope
        && model.settings.planID == planID
    }
    defer {
      if stillCurrent() {
        isLoadingBrief = false
      }
    }
    let spec = LedgerQuerySpec(
      kind: .today,
      category: "",
      account: "",
      merchant: "",
      from: "",
      to: ""
    )
    switch LedgerQueryPlanner.resolve(
      spec: spec,
      accounts: model.accounts,
      categoryGroups: model.categoryGroups
    ) {
    case .failure(let error):
      guard stillCurrent() else {
        return
      }
      briefError = error.localizedDescription
      brief = nil
    case .success(let resolution):
      do {
        let report = try await client.fetchSpendingBreakdown(
          planID: planID,
          from: resolution.from,
          to: resolution.to,
          accountIDs: resolution.accountIDs,
          categoryIDs: resolution.categoryIDs
        )
        guard stillCurrent() else {
          return
        }
        let total = LedgerQueryPlanner.recordedSpendingTotal(
          from: report,
          includeQuiet: model.includeQuietSpending
        )
        let money = MoneyCodec.displayString(for: -total, currencyFormat: model.currencyFormat)
        let source = await loadBriefSource(
          resolution,
          client: client,
          settingsScope: settingsScope,
          workspaceScope: workspaceScope,
          planID: planID,
          generation: generation
        )
        guard stillCurrent() else {
          return
        }
        brief = LedgerQueryResult(
          title: "Today",
          detail: "\(money) recorded spending today",
          totalMilliunits: total,
          comparisonMilliunits: nil,
          from: resolution.from,
          to: resolution.to,
          accountLabel: resolution.accountLabel,
          categoryLabel: resolution.categoryLabel,
          sourceRows: source,
          sourceCount: source.count,
          isPreview: false,
          isRecordedSpending: true,
          isUnavailable: false
        )
        briefDay = resolution.from
        briefError = nil
      } catch {
        guard stillCurrent() else {
          return
        }
        brief = nil
        briefError = "Recorded spending is unavailable. \(error.localizedDescription)"
      }
    }
  }

  private func loadBriefSource(
    _ resolution: LedgerQueryResolution,
    client: APIClient,
    settingsScope: String?,
    workspaceScope: String?,
    planID: String,
    generation: Int
  ) async -> [LedgerQuerySourceRow] {
    do {
      let rows = try await LedgerQueryRunner.fetchAllTransactions(
        client: client,
        planID: planID,
        accountID: resolution.accountIDs.first,
        sinceDate: resolution.from,
        untilDate: resolution.to,
        isCancelled: {
          generation != briefGeneration
            || model.settings.viewPrefsScopeKey != settingsScope
            || workspace.activeScopeKey != workspaceScope
            || model.settings.planID != planID
        }
      )
      guard generation == briefGeneration,
            model.settings.viewPrefsScopeKey == settingsScope,
            workspace.activeScopeKey == workspaceScope,
            model.settings.planID == planID
      else {
        return []
      }
      return LedgerQueryPlanner.sourceRows(
        from: rows,
        resolution: resolution,
        categoryGroups: model.categoryGroups,
        includeQuiet: model.includeQuietSpending
      )
    } catch {
      return []
    }
  }
}

private struct AssistantBriefRefreshKey: Hashable {
  var scope: String?
  var reportsGeneration: Int
}

private extension CaptureSessionSnapshot {
  var titleFallback: String {
    drafts.first?.draft.payeeName.isEmpty == false
      ? drafts[0].draft.payeeName
      : "Unfinished capture"
  }

  var unsavedDraftCount: Int {
    drafts.filter { !$0.committed }.count
  }
}
