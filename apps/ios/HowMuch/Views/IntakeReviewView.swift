import SwiftUI

/// The batch review: the source documents above, the proposals below grouped
/// Fix, New, Possible duplicates and Already in, and Approve at the bottom.
/// Reading the documents and matching never write to the ledger; only Approve
/// does, through `IntakeCoordinator.approve`.
struct IntakeReviewView: View {
  let jobID: UUID
  /// Replaces `dismiss` for Close, for a screen that is a pane rather than a push.
  var onClose: (() -> Void)?

  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome: RootChromeState?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  @State private var confirmingDiscard = false
  @State private var isApproving = false
  @State private var pages: [IntakeViewerPage] = []
  @State private var page = 0
  @State private var isViewerExpanded = true
  @State private var hasSetInitialExpansion = false
  @State private var highlightedID: UUID?
  @State private var scrollRequest: UUID?
  /// Existing rows that Possible duplicates look like, read once per batch.
  @State private var existing: [String: Transaction] = [:]
  @State private var editing: ProposalRef?
  @State private var whyTarget: ProposalRef?
  @State private var matchTarget: ProposalRef?
  /// The one rule offered after an approval, if a correction generalises.
  @State private var suggestion: IntakeRuleSuggestion?

  private var coordinator: IntakeCoordinator { .shared }

  private struct ProposalRef: Identifiable {
    let id: UUID
  }

  /// The viewer takes about this share of the screen.
  private static let viewerShare: CGFloat = 0.38

  var body: some View {
    Group {
      if let job = coordinator.job(jobID) {
        content(for: job)
      } else {
        ContentUnavailableView("Batch not found", systemImage: "tray")
      }
    }
    .background(Theme.canvas)
    .navigationBarTitleDisplayMode(.inline)
    // A push keeps the system Back and swipe-back; a pane supplies Close.
    .navigationBarBackButtonHidden(onClose != nil)
    .toolbar {
      if onClose != nil {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            close()
          }
          .tint(Theme.accent)
        }
      }
      ToolbarItem(placement: .principal) {
        titleView
      }
      if hasOptions {
        ToolbarItem(placement: .primaryAction) {
          optionsMenu
        }
      }
    }
    .binaryConfirm(
      LocalizedStringKey(discardTitle),
      isPresented: $confirmingDiscard,
      confirm: .destructive("Discard"),
      message: {
        Text(discardMessage)
      }
    ) {
      coordinator.discard(jobID)
      close()
    }
    .sheet(item: $editing) { reference in
      if let proposal = proposal(reference.id) {
        NavigationStack {
          TransactionFormView(
            draft: proposal.draft,
            isEditing: false,
            allowsDeletion: false,
            chrome: .sessionEditor,
            onPersist: { updated in
              if let refusal = coordinator.updateDraft(updated, proposal: reference.id, in: jobID, model: model) {
                model.showSaveMessage(refusal, kind: .failure)
              }
            }
          )
        }
        .presentationDetents([.large])
        .blocksCapturePresentation()
      }
    }
    .sheet(item: $whyTarget) { reference in
      if let proposal = proposal(reference.id) {
        IntakeWhySheet(proposal: proposal)
      }
    }
    .sheet(item: $matchTarget) { reference in
      if let proposal = proposal(reference.id), let job = coordinator.job(jobID) {
        IntakeMatchSheet(
          proposal: proposal,
          known: existing,
          takenIDs: Set(job.proposals.compactMap { $0.id == proposal.id ? nil : $0.targetTransactionID })
        ) { candidateID in
          Task {
            let flipped = await coordinator.flipToFix(reference.id, candidate: candidateID, in: jobID, model: model)
            if !flipped {
              model.showSaveMessage("Couldn’t read that transaction. Try again.", kind: .failure)
            }
          }
        }
      }
    }
    .sheet(item: $suggestion, onDismiss: {
      // The batch stays on screen behind the sheet until it is answered.
      if coordinator.job(jobID)?.state == .applied {
        close()
      }
    }) { offered in
      RememberThisSheet(suggestion: offered)
        .presentationDetents([.medium, .large])
        .blocksCapturePresentation()
    }
    .task(id: pagesKey) {
      await loadPages()
    }
    .task(id: neededExistingIDs) {
      await loadExisting()
    }
    .task {
      coordinator.drain(model: model)
    }
  }

  // MARK: Navigation bar

  private var titleView: some View {
    VStack(spacing: 0) {
      Text("Review")
        .font(.headline)
        .foregroundStyle(Theme.textPrimary)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  /// "DBS Altitude screenshots · 09:41".
  private var subtitle: String? {
    guard let job = coordinator.job(jobID) else {
      return nil
    }
    return "\(job.title(accountName: accountName(for: job))) · \(IntakeTime.label(for: job.createdAt))"
  }

  /// The menu has something to offer only before the batch is finished.
  private var hasOptions: Bool {
    guard let job = coordinator.job(jobID) else {
      return false
    }
    return job.state != .applied && job.state != .discarded
  }

  /// Saved rows stay in the register, so discarding says it only drops the rest.
  private var hasAppliedRows: Bool {
    coordinator.job(jobID)?.proposals.contains(where: \.isApplied) ?? false
  }

  private var discardTitle: String {
    hasAppliedRows ? "Discard the rest?" : "Discard this batch?"
  }

  private var discardMessage: String {
    hasAppliedRows ? "Saved rows stay in the register." : "Nothing was saved."
  }

  @ViewBuilder
  private var optionsMenu: some View {
    if let job = coordinator.job(jobID), hasOptions {
      Menu {
        if job.state == .proposed || (job.state == .needsYou && job.hint != .statement) {
          Menu {
            ForEach(model.openAccounts) { account in
              Button(account.name) {
                changeAccountForAll(account.id, job: job)
              }
            }
          } label: {
            Label("Change account for all", systemImage: "building.columns")
          }
        }
        Button(role: .destructive) {
          confirmingDiscard = true
        } label: {
          Label("Discard batch", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .frame(minWidth: 44, minHeight: 44)
      }
      .disabled(isApproving)
      .accessibilityLabel("Batch options")
    }
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  // MARK: States

  @ViewBuilder
  private func content(for job: IntakeJob) -> some View {
    switch job.state {
    case .queued, .reading:
      ZStack {
        Theme.canvas
        IntelligenceAura()
        VStack(spacing: 8) {
          Text(job.waitingMessage ?? "Reading on this phone…")
            .font(.headline)
          Text(job.waitingMessage == nil
            ? "Rows appear here when the reader finishes."
            : "Reading starts when they load.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
      }
      .accessibilityElement(children: .combine)
    case .failed:
      ContentUnavailableView {
        Label("Couldn’t read this document", systemImage: "exclamationmark.triangle")
      } description: {
        Text(job.failureMessage ?? "Couldn’t read this.")
      } actions: {
        if job.failureMessage != IntakeCoordinator.differentBudgetMessage {
          Button("Try Again") {
            coordinator.retry(job.id, model: model)
          }
          .buttonStyle(.borderedProminent)
          .tint(Theme.accent)
        }
        Button("Discard", role: .destructive) {
          confirmingDiscard = true
        }
        .tint(Theme.cancellation)
      }
    case .discarded:
      ContentUnavailableView("Discarded", systemImage: "trash")
    case .needsYou, .proposed, .applied:
      review(job)
    }
  }

  private func review(_ job: IntakeJob) -> some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if !pages.isEmpty {
          IntakeDocumentViewer(
            pages: pages,
            page: $page,
            isExpanded: $isViewerExpanded,
            height: proxy.size.height * Self.viewerShare,
            showsHint: !job.proposals.isEmpty,
            onToggle: {
              animate { isViewerExpanded.toggle() }
            }
          )
          .padding(.horizontal, 16)
          .padding(.top, 8)
        }
        ScrollViewReader { reader in
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              banners(for: job)
              ForEach(Self.groups, id: \.title) { group in
                let rows = job.proposals.filter { $0.kind == group.kind }
                if !rows.isEmpty {
                  Text(group.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                  ForEach(rows) { proposal in
                    row(proposal, in: job)
                      .id(proposal.id)
                  }
                }
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
          .onChange(of: scrollRequest) { _, id in
            guard let id else {
              return
            }
            animate { reader.scrollTo(id, anchor: .center) }
            scrollRequest = nil
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if job.state == .proposed {
              actionBar(for: job)
            }
          }
        }
      }
    }
    .onChange(of: page) { _, newPage in
      pageChanged(to: newPage, in: job)
    }
  }

  private static let groups: [(title: String, kind: IntakeProposalKind)] = [
    ("FIX", .edit),
    ("NEW", .add),
    ("POSSIBLE DUPLICATES", .possibleDuplicate),
    ("ALREADY IN", .alreadyIn),
  ]

  @ViewBuilder
  private func banners(for job: IntakeJob) -> some View {
    if job.state == .needsYou {
      needsYouBanner(for: job)
    }
    if job.state == .applied {
      Label(job.appliedSummary ?? "Applied", systemImage: "checkmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.inflow)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
    if let note = job.note, !note.isEmpty {
      VStack(alignment: .trailing, spacing: 4) {
        Text(note)
          .font(.body)
          .foregroundStyle(Theme.card)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // This version reads documents only; it does not act on notes yet.
        Label("Notes aren’t read yet", systemImage: "exclamationmark.circle")
          .font(.footnote)
          .foregroundStyle(Theme.uncategorised)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Your note: \(note). Notes aren’t read yet")
    }
  }

  private func needsYouBanner(for job: IntakeJob) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if job.hint == .statement {
        Label("Needs a later version", systemImage: "exclamationmark.circle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.uncategorised)
      } else {
        Label("Choose an account to continue", systemImage: "exclamationmark.circle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.uncategorised)
      }
      if let message = job.failureMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if job.hint != .statement {
        Menu {
          ForEach(model.openAccounts) { account in
            Button(account.name) {
              Task { await coordinator.assignAccount(account.id, to: job.id, model: model) }
            }
          }
        } label: {
          Label("Choose account", systemImage: "building.columns")
            .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        .strokeBorder(Theme.uncategorised.opacity(0.5), lineWidth: 1)
    }
  }

  // MARK: Rows

  private func row(_ proposal: IntakeProposal, in job: IntakeJob) -> some View {
    let reviewable = job.state == .proposed && !isApproving
    let chips = candidateChips(for: proposal, in: job)
    return IntakeProposalRow(
      proposal: proposal,
      isReadOnly: !reviewable,
      isHighlighted: highlightedID == proposal.id,
      existing: existingRow(for: proposal),
      accountCandidates: chips.account,
      categoryCandidates: chips.category,
      onToggle: {
        if proposal.isIncomplete {
          // An incomplete row cannot be ticked; it can only be skipped or not.
          coordinator.setDecision(
            proposal.decision == .rejected ? .pending : .rejected, proposal: proposal.id, in: job.id, model: model
          )
        } else {
          let ticked = proposal.appliesOnApproval
          coordinator.setDecision(ticked ? .rejected : .accepted, proposal: proposal.id, in: job.id, model: model)
        }
      },
      onOpen: {
        select(proposal)
        editing = ProposalRef(id: proposal.id)
      },
      onWhy: {
        select(proposal)
        whyTarget = ProposalRef(id: proposal.id)
      },
      onViewExisting: {
        if let row = existingRow(for: proposal) {
          chrome?.showAccount(row.accountID)
        }
      },
      onMatchExisting: {
        matchTarget = ProposalRef(id: proposal.id)
      },
      onMakeNew: {
        coordinator.flipToNew(proposal.id, in: job.id, model: model)
      },
      onPickAccount: { accountID in
        if let refusal = coordinator.setAccount(accountID, proposal: proposal.id, in: job.id, model: model) {
          model.showSaveMessage(refusal, kind: .failure)
        }
      },
      onPickAccountForAll: { accountID in
        coordinator.setAccountForAll(accountID, in: job.id, model: model)
      },
      onPickCategory: { categoryID in
        var draft = proposal.draft
        draft.categoryID = categoryID
        if let refusal = coordinator.updateDraft(draft, proposal: proposal.id, in: job.id, model: model) {
          model.showSaveMessage(refusal, kind: .failure)
        }
      }
    )
  }

  private func proposal(_ id: UUID) -> IntakeProposal? {
    coordinator.job(jobID)?.proposals.first { $0.id == id }
  }

  private func existingRow(for proposal: IntakeProposal) -> Transaction? {
    switch proposal.kind {
    case .edit, .alreadyIn:
      return proposal.targetSnapshot
    case .possibleDuplicate:
      return proposal.candidateIDs.first.flatMap { existing[$0] }
    case .add:
      return nil
    }
  }

  /// The reader's guesses for a line's account and category, when the job
  /// still holds what the reader extracted for it.
  private func candidateChips(
    for proposal: IntakeProposal,
    in job: IntakeJob
  ) -> (account: [SlipCandidate], category: [SlipCandidate]) {
    guard job.extractions.count == job.proposals.count,
          let index = job.proposals.firstIndex(where: { $0.id == proposal.id }) else {
      return ([], [])
    }
    return (job.extractions[index].accountCandidates, job.extractions[index].categoryCandidates)
  }

  // MARK: Viewer and rows stay in step

  private func pageIndex(for proposal: IntakeProposal) -> Int? {
    guard let source = proposal.sourceFileIndex else {
      return nil
    }
    return pages.firstIndex { $0.fileIndex == source }
  }

  /// Tapping a row highlights it and shows where it came from.
  private func select(_ proposal: IntakeProposal) {
    highlightedID = proposal.id
    if let target = pageIndex(for: proposal), target != page {
      animate { page = target }
    }
  }

  /// Swiping the viewer highlights the first row read from that page, unless
  /// the highlighted row is already on it.
  private func pageChanged(to newPage: Int, in job: IntakeJob) {
    guard pages.indices.contains(newPage) else {
      return
    }
    let fileIndex = pages[newPage].fileIndex
    if let current = highlightedID,
       job.proposals.first(where: { $0.id == current })?.sourceFileIndex == fileIndex {
      return
    }
    if let match = job.proposals.first(where: { $0.sourceFileIndex == fileIndex }) {
      highlightedID = match.id
      scrollRequest = match.id
    }
  }

  private func animate(_ change: () -> Void) {
    if reduceMotion {
      change()
    } else {
      withAnimation(Theme.Motion.standard, change)
    }
  }

  /// Changes whenever the files or the job's state do, so the pages are
  /// listed again after a retry or once the files have been deleted.
  private var pagesKey: String {
    guard let job = coordinator.job(jobID) else {
      return ""
    }
    return "\(job.state.rawValue)-" + job.sourceFiles.map(\.filename).joined(separator: ",")
  }

  private func loadPages() async {
    guard let job = coordinator.job(jobID) else {
      pages = []
      return
    }
    var result: [IntakeViewerPage] = []
    for (index, file) in job.sourceFiles.enumerated() {
      let url = coordinator.sourceURL(file, jobID: jobID)
      guard FileManager.default.fileExists(atPath: url.path) else {
        continue
      }
      switch file.kind {
      case .image:
        result.append(IntakeViewerPage(id: "\(index)", fileIndex: index, url: url, kind: .image, pdfPage: 0))
      case .pdf:
        let count = await IntakeSourceImage.pdfPageCount(url)
        for pdfPage in 0..<count {
          result.append(
            IntakeViewerPage(id: "\(index)-\(pdfPage)", fileIndex: index, url: url, kind: .pdf, pdfPage: pdfPage)
          )
        }
      case .text:
        break
      }
    }
    guard !Task.isCancelled else {
      return
    }
    pages = result
    page = min(page, max(result.count - 1, 0))
    // In landscape the rows need the room: start with the original collapsed.
    if !hasSetInitialExpansion {
      hasSetInitialExpansion = true
      if verticalSizeClass == .compact {
        isViewerExpanded = false
      }
    }
  }

  // MARK: Existing rows

  /// Candidate rows still to read: the one each Possible duplicate looks like.
  private var neededExistingIDs: [String] {
    guard let job = coordinator.job(jobID), job.state == .proposed || job.state == .needsYou else {
      return []
    }
    return job.proposals
      .filter { $0.kind == .possibleDuplicate && !$0.isApplied }
      .compactMap(\.candidateIDs.first)
  }

  private func loadExisting() async {
    for id in neededExistingIDs where existing[id] == nil {
      if let row = await model.intakeLiveTransaction(id: id) {
        existing[id] = row
      }
    }
  }

  // MARK: Bottom bar

  private func actionBar(for job: IntakeJob) -> some View {
    let actionable = job.proposals.filter { !$0.isApplied && $0.kind != .alreadyIn }
    let approvable = actionable.filter { !$0.isIncomplete }
    let ticked = approvable.filter(\.appliesOnApproval)
    let blocked = actionable.filter { $0.isIncomplete && $0.decision != .rejected }.count

    let title: String
    if actionable.isEmpty {
      title = "Done"
    } else if ticked.isEmpty {
      title = "Select rows to approve"
    } else if ticked.count == approvable.count {
      title = "Approve all \(ticked.count)"
    } else {
      title = "Approve \(ticked.count) selected"
    }
    let canApprove = actionable.isEmpty || !ticked.isEmpty

    return VStack(spacing: 4) {
      if blocked > 0 {
        Text(
          blocked == 1
            ? "1 row can’t be approved yet and will be skipped."
            : "\(blocked) rows can’t be approved yet and will be skipped."
        )
        .font(.footnote)
        .foregroundStyle(Theme.uncategorised)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button {
        approve(job)
      } label: {
        Text(title)
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .disabled(!canApprove || isApproving)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(Theme.accent)

      Button("Reject batch", role: .destructive) {
        confirmingDiscard = true
      }
      .frame(minHeight: 44)
      .disabled(isApproving)
      .tint(Theme.cancellation)
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 4)
    .background(.ultraThinMaterial)
  }

  private func approve(_ job: IntakeJob) {
    isApproving = true
    let alreadyApplied = Set(job.proposals.filter(\.isApplied).map(\.id))
    Task {
      let done = await coordinator.approve(job.id, model: model)
      isApproving = false
      guard done, let after = coordinator.job(job.id) else {
        return
      }
      // After an approval only, never a reject: offer at most one rule from what
      // the owner changed in the rows this approval saved.
      suggestion = IntakeRuleSuggester.suggest(
        applied: after.proposals.filter { $0.isApplied && !alreadyApplied.contains($0.id) },
        jobID: after.id,
        skill: IntakeSkillStore.shared.skill
      )
      if suggestion != nil {
        // One offer per batch, ever, whatever the answer.
        IntakeSkillStore.shared.markOffered(after.id)
      }
      // Stay on the screen unless the batch is finished: skipped rows need the owner.
      // With a rule on offer, closing waits for the sheet.
      if suggestion == nil, after.state == .applied {
        close()
      }
    }
  }

  private func changeAccountForAll(_ accountID: String, job: IntakeJob) {
    if job.state == .needsYou {
      Task { await coordinator.assignAccount(accountID, to: job.id, model: model) }
    } else {
      coordinator.setAccountForAll(accountID, in: job.id, model: model)
    }
  }

  private func accountName(for job: IntakeJob) -> String? {
    guard let id = job.accountID else {
      return nil
    }
    return model.accounts.first { $0.id == id }?.name
  }
}

/// Why a row was proposed the way it was: how sure the matcher is, and the
/// reasons it recorded.
private struct IntakeWhySheet: View {
  let proposal: IntakeProposal
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let confidence = IntakeConfidence(proposal.confidence)
    NavigationStack {
      List {
        Section {
          HStack(spacing: 8) {
            Circle()
              .fill(confidence.colour)
              .frame(width: 10, height: 10)
              .accessibilityHidden(true)
            Text(confidence.word)
              .font(.body.weight(.semibold))
              .foregroundStyle(confidence.colour)
            Text("· proposed as \(proposal.kind.reviewWord.lowercased())")
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
        .listRowBackground(Theme.card)
        Section("Reasons") {
          if proposal.reasons.isEmpty {
            Text("No further detail.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(proposal.reasons.enumerated()), id: \.offset) { _, reason in
              Text(reason)
                .accessibilityLabel(reason.replacingOccurrences(of: " → ", with: ", "))
            }
          }
        }
        .listRowBackground(Theme.card)
      }
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .navigationTitle("Why")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Lets the owner say a New row is really a fix of one of the existing
/// transactions it looked like.
private struct IntakeMatchSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let proposal: IntakeProposal
  let known: [String: Transaction]
  /// Rows another line in the batch already fixes.
  let takenIDs: Set<String>
  let onChoose: (String) -> Void
  @State private var rows: [Transaction] = []
  @State private var isLoading = true

  var body: some View {
    NavigationStack {
      List {
        if rows.isEmpty {
          if isLoading {
            ProgressView()
              .frame(maxWidth: .infinity)
              .listRowBackground(Color.clear)
          } else {
            Text("No existing transactions to match.")
              .foregroundStyle(.secondary)
              .listRowBackground(Theme.card)
          }
        }
        ForEach(rows) { row in
          Button {
            onChoose(row.id)
            dismiss()
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .firstTextBaseline) {
                Text((row.payeeName ?? "").isEmpty ? "No payee" : (row.payeeName ?? ""))
                  .font(.body.weight(.semibold))
                  .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(MoneyCodec.displayString(for: row.amount, currencyFormat: model.currencyFormat))
                  .font(.body.weight(.semibold))
                  .monospacedDigit()
                  .foregroundStyle(Theme.amountColour(row.amount))
              }
              Text("\(dateText(row.date)) · \(row.accountName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(Theme.card)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .navigationTitle("Match to existing")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      .task {
        await load()
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func load() async {
    var found: [Transaction] = []
    for id in proposal.candidateIDs where !takenIDs.contains(id) {
      if let row = known[id] {
        found.append(row)
      } else if let row = await model.intakeLiveTransaction(id: id) {
        found.append(row)
      }
    }
    rows = found
    isLoading = false
  }

  private func dateText(_ iso: String) -> String {
    Date(isoDateString: iso).map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? iso
  }
}
