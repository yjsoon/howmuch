import SwiftUI
import UIKit

/// The Inbox band at the top of Accounts: shown only when there is something
/// in the Inbox, with the two most urgent batches.
struct IntakeInboxBand: View {
  @Environment(AppModel.self) private var model
  var onSeeAll: () -> Void
  var onOpen: (IntakeJob) -> Void

  private var coordinator: IntakeCoordinator { .shared }

  var body: some View {
    let urgent = Array(coordinator.mostUrgent.prefix(2))
    if !urgent.isEmpty {
      let open = coordinator.attentionCount
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "tray.and.arrow.down")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
          Text("Inbox")
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
          if open > 0 {
            Text("\(open)")
              .font(.caption.weight(.semibold))
              .monospacedDigit()
              .foregroundStyle(Theme.accent)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Theme.accent.opacity(0.14), in: Capsule())
              .accessibilityLabel("\(open) waiting")
          }
          Spacer()
          Button("See all", action: onSeeAll)
            .font(.subheadline.weight(.semibold))
            .tint(Theme.accent)
        }
        .padding(.horizontal, 4)

        VStack(spacing: 0) {
          ForEach(Array(urgent.enumerated()), id: \.element.id) { index, job in
            if index > 0 {
              Divider().padding(.leading, 68)
            }
            Button {
              onOpen(job)
            } label: {
              IntakeJobRow(job: job, accountName: accountName(for: job))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .ynabCard()
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

/// One batch: thumbnail, source-derived title, status pill with summary, time.
struct IntakeJobRow: View {
  let job: IntakeJob
  var accountName: String?

  var body: some View {
    HStack(spacing: 12) {
      IntakeJobThumbnail(job: job)
      VStack(alignment: .leading, spacing: 4) {
        Text(job.title(accountName: accountName))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
        HStack(spacing: 6) {
          IntakeStatusPill(state: job.state)
          Text(job.statusSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      Text(IntakeTime.label(for: job.createdAt))
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .background {
      if job.state == .reading || job.state == .queued {
        // The aura is the only "working" signal; it holds still under Reduce Motion.
        IntelligenceAura(intensity: 0.3)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(job.title(accountName: accountName)), \(IntakeStatusPill.spokenLabel(for: job.state)), "
        + "\(job.spokenStatusSummary), \(IntakeTime.label(for: job.createdAt))"
    )
  }
}

enum IntakeTime {
  /// "09:41" today, otherwise "6 Oct".
  static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.day().month(.abbreviated))
  }
}

/// Reading (grey), Ready (accent), Needs you (amber), Applied (green tick),
/// Failed (red). Each has a word, so colour is never the only signal.
struct IntakeStatusPill: View {
  let state: IntakeJobState

  var body: some View {
    HStack(spacing: 3) {
      if state == .applied {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
      }
      Text(Self.label(for: state))
        .font(.caption2.weight(.semibold))
    }
    .foregroundStyle(Self.colour(for: state))
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(Self.colour(for: state).opacity(0.14), in: Capsule())
  }

  static func label(for state: IntakeJobState) -> String {
    switch state {
    case .queued, .reading: "Reading"
    case .proposed: "Ready"
    case .needsYou: "Needs you"
    case .applied: "Applied"
    case .discarded: "Discarded"
    case .failed: "Failed"
    }
  }

  static func spokenLabel(for state: IntakeJobState) -> String {
    switch state {
    case .queued, .reading: "reading"
    case .proposed: "ready to review"
    case .needsYou: "needs you"
    case .applied: "applied"
    case .discarded: "discarded"
    case .failed: "failed"
    }
  }

  static func colour(for state: IntakeJobState) -> Color {
    switch state {
    case .queued, .reading, .discarded: Color.secondary
    case .proposed: Theme.accent
    case .needsYou: Theme.uncategorised
    case .applied: Theme.inflow
    case .failed: Theme.outflow
    }
  }
}

/// A small preview of the first image in a batch, or a symbol for a PDF, text,
/// or a batch whose files have been deleted.
struct IntakeJobThumbnail: View {
  let job: IntakeJob
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous)
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Theme.surfaceMuted
        Image(systemName: symbol)
          .font(.body.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 44, height: 44)
    .clipShape(shape)
    .accessibilityHidden(true)
    .task(id: "\(job.id.uuidString)-\(job.state.rawValue)") {
      guard job.state != .applied, job.sourceFiles.contains(where: { $0.kind == .image }) else {
        image = nil
        return
      }
      let items = IntakeCoordinator.shared.thumbnailSource(for: job)
      image = try? await InboxPreview.firstThumbnail(in: items, displayScale: displayScale)
    }
  }

  private var symbol: String {
    switch job.sourceFiles.first?.kind {
    case .pdf: "doc.richtext"
    case .text: "text.alignleft"
    default: "photo"
    }
  }
}
