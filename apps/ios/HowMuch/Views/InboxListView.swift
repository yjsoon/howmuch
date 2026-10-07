import SwiftUI

struct IntakeRoute: Hashable {
  let jobID: UUID
}

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
            IntakeReviewView(jobID: job.id)
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
