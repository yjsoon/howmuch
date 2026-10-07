import SwiftUI

/// The Inbox: every batch shared to Halation, grouped by what it needs.
struct InboxListView: View {
  @Environment(AppModel.self) private var model
  @State private var pendingDiscard: IntakeJob?

  private var coordinator: IntakeCoordinator { .shared }

  var body: some View {
    let jobs = coordinator.jobs
    Group {
      if jobs.isEmpty {
        ContentUnavailableView {
          Label("Nothing waiting", systemImage: "tray")
        } description: {
          Text("Share a screenshot or statement to Halation and it will appear here.")
        }
      } else {
        List {
          section("Needs you", jobs.filter { $0.state == .needsYou })
          section("Ready to review", jobs.filter { $0.state == .proposed })
          section("Reading", jobs.filter { $0.state == .reading || $0.state == .queued })
          section("Applied", jobs.filter { $0.state == .applied })
          section("Failed", jobs.filter { $0.state == .failed })
        }
        .scrollContentBackground(.hidden)
      }
    }
    .background(Theme.canvas)
    .navigationTitle("Inbox")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            coordinator.clearApplied()
          } label: {
            Label("Clear applied", systemImage: "checkmark.circle")
          }
          .disabled(!jobs.contains { $0.state == .applied })
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Inbox options")
      }
    }
    .binaryConfirm(
      "Discard this batch?",
      presenting: $pendingDiscard,
      confirm: .destructive("Discard"),
      message: { _ in
        Text("Nothing was saved.")
      }
    ) { job in
      coordinator.discard(job.id)
    }
    .task {
      coordinator.drain(model: model)
    }
  }

  @ViewBuilder
  private func section(_ title: String, _ jobs: [IntakeJob]) -> some View {
    if !jobs.isEmpty {
      Section(title) {
        ForEach(jobs) { job in
          // A view destination, not a value: this list is itself pushed by the
          // Accounts pane, where a value destination isn't visible to the link.
          NavigationLink {
            IntakeBatchDetailView(jobID: job.id)
          } label: {
            IntakeJobRow(job: job, accountName: accountName(for: job))
          }
          .listRowBackground(Theme.card)
          .swipeActions(edge: .trailing, allowsFullSwipe: job.state != .applied) {
            if job.state == .applied {
              Button {
                coordinator.remove(job.id)
              } label: {
                Label("Clear", systemImage: "xmark.circle")
              }
              .tint(Theme.accent)
            } else {
              Button {
                pendingDiscard = job
              } label: {
                Label("Discard", systemImage: "trash")
              }
              .tint(Theme.cancellation)
            }
            if job.state == .failed {
              Button {
                coordinator.retry(job.id, model: model)
              } label: {
                Label("Retry", systemImage: "arrow.clockwise")
              }
              .tint(Theme.accent)
            }
          }
        }
      }
    }
  }

  private func accountName(for job: IntakeJob) -> String? {
    guard let id = job.accountID else {
      return nil
    }
    return model.accounts.first { $0.id == id }?.name
  }
}

/// The first version of a batch's detail: proposals grouped Fix, New, Possible
/// duplicates and Already in, with Approve all and Reject batch. The full
/// review screen (document viewer, per-row checkboxes, edit) replaces this.
struct IntakeBatchDetailView: View {
  let jobID: UUID
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingReject = false
  @State private var isApproving = false

  private var coordinator: IntakeCoordinator { .shared }

  var body: some View {
    Group {
      if let job = coordinator.job(jobID) {
        content(for: job)
          .navigationTitle(job.title(accountName: accountName(for: job)))
      } else {
        ContentUnavailableView("Batch not found", systemImage: "tray")
          .navigationTitle("Inbox")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .background(Theme.canvas)
    .binaryConfirm(
      "Discard this batch?",
      isPresented: $confirmingReject,
      confirm: .destructive("Discard"),
      message: {
        Text("Nothing was saved.")
      }
    ) {
      coordinator.discard(jobID)
      dismiss()
    }
  }

  @ViewBuilder
  private func content(for job: IntakeJob) -> some View {
    switch job.state {
    case .queued, .reading:
      ZStack {
        Theme.canvas
        IntelligenceAura()
        VStack(spacing: 8) {
          Text("Reading on this phone…")
            .font(.headline)
          Text("Rows appear here when the reader finishes.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(24)
      }
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
        }
        Button("Discard", role: .destructive) {
          confirmingReject = true
        }
        .tint(Theme.cancellation)
      }
    case .discarded:
      ContentUnavailableView("Discarded", systemImage: "trash")
    case .needsYou, .proposed, .applied:
      proposals(for: job)
    }
  }

  private func proposals(for job: IntakeJob) -> some View {
    let groups: [(title: String, kind: IntakeProposalKind)] = [
      ("FIX", .edit),
      ("NEW", .add),
      ("POSSIBLE DUPLICATES", .possibleDuplicate),
      ("ALREADY IN", .alreadyIn),
    ]
    return List {
      if job.state == .needsYou {
        Section {
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
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if job.hint != .statement, !model.openAccounts.isEmpty {
              Menu {
                ForEach(model.openAccounts) { account in
                  Button(account.name) {
                    Task { await coordinator.assignAccount(account.id, to: job.id, model: model) }
                  }
                }
              } label: {
                Label("Choose account", systemImage: "building.columns")
              }
              .buttonStyle(.bordered)
            }
          }
          .listRowBackground(Theme.card)
        }
      }
      if job.state == .applied {
        Section {
          Label(job.appliedSummary ?? "Applied", systemImage: "checkmark.circle.fill")
            .foregroundStyle(Theme.inflow)
            .listRowBackground(Theme.card)
        }
      }
      if let note = job.note, !note.isEmpty {
        Section("Your note") {
          VStack(alignment: .leading, spacing: 4) {
            Text(note)
              .font(.subheadline)
            // This version reads documents only; it does not act on notes yet.
            Label("Couldn’t apply this note", systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(Theme.uncategorised)
          }
          .listRowBackground(Theme.card)
        }
      }
      ForEach(groups, id: \.title) { group in
        let rows = job.proposals.filter { $0.kind == group.kind }
        if !rows.isEmpty {
          Section(group.title) {
            ForEach(rows) { proposal in
              proposalRow(proposal, in: job)
                .listRowBackground(Theme.card)
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .safeAreaInset(edge: .bottom) {
      if job.state == .proposed {
        actionBar(for: job)
      }
    }
  }

  private func proposalRow(_ proposal: IntakeProposal, in job: IntakeJob) -> some View {
    let draft = proposal.draft
    let payee = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(payee.isEmpty ? "No payee" : payee)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
        Spacer(minLength: 8)
        Text(MoneyCodec.displayString(for: draft.signedMilliunits, currencyFormat: model.currencyFormat))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(draft.signedMilliunits))
      }
      Text(detailLine(for: proposal))
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(proposal.reasons, id: \.self) { reason in
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let issue = proposal.issue {
        Text(issue)
          .font(.caption)
          .foregroundStyle(Theme.uncategorised)
      } else if proposal.isIncomplete, !proposal.isResolved {
        Text("Can’t be added as read. Approve all skips it.")
          .font(.caption)
          .foregroundStyle(Theme.uncategorised)
      }
      if proposal.isApplied {
        Label("Applied", systemImage: "checkmark")
          .font(.caption)
          .foregroundStyle(Theme.inflow)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func detailLine(for proposal: IntakeProposal) -> String {
    let account = model.accounts.first { $0.id == proposal.draft.accountID }?.name ?? "No account"
    let date = proposal.draft.date.formatted(.dateTime.day().month(.abbreviated))
    return "\(date) · \(account) · \(confidenceWord(proposal.confidence))"
  }

  private func confidenceWord(_ confidence: Double) -> String {
    switch confidence {
    case 0.9...: "Sure"
    case 0.75...: "Likely"
    default: "Unsure"
    }
  }

  private func actionBar(for job: IntakeJob) -> some View {
    let count = job.proposals.filter(\.appliesOnApproval).count
    return VStack(spacing: 8) {
      Button {
        isApproving = true
        Task {
          let done = await coordinator.approve(job.id, model: model)
          isApproving = false
          if done, coordinator.job(job.id)?.state == .applied {
            dismiss()
          }
        }
      } label: {
        Text(count > 0 ? "Approve all \(count)" : "Done")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .disabled(isApproving)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(Theme.accent)

      Button("Reject batch", role: .destructive) {
        confirmingReject = true
      }
      .tint(Theme.cancellation)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial)
  }

  private func accountName(for job: IntakeJob) -> String? {
    guard let id = job.accountID else {
      return nil
    }
    return model.accounts.first { $0.id == id }?.name
  }
}
