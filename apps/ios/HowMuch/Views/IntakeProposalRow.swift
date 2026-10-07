import SwiftUI

/// How sure the matcher is, as a word and a dot. The word is always shown so
/// colour is never the only signal.
enum IntakeConfidence: Equatable {
  case sure
  case likely
  case unsure

  init(_ confidence: Double) {
    switch confidence {
    case 0.9...: self = .sure
    case 0.75...: self = .likely
    default: self = .unsure
    }
  }

  var word: String {
    switch self {
    case .sure: "Sure"
    case .likely: "Likely"
    case .unsure: "Unsure"
    }
  }

  var colour: Color {
    switch self {
    case .sure: Theme.inflow
    case .likely: Theme.accent
    case .unsure: Theme.uncategorised
    }
  }
}

extension IntakeProposalKind {
  /// "Fix", "New", "Possible duplicate", "Already in".
  var reviewWord: String {
    switch self {
    case .edit: "Fix"
    case .add: "New"
    case .possibleDuplicate: "Possible duplicate"
    case .alreadyIn: "Already in"
    }
  }
}

/// One proposed line in the batch review: checkbox, what will be saved (for a
/// Fix, only what changes, old struck through), confidence, and the controls
/// that resolve what the row is missing. The checkbox and the Why button are
/// their own controls; tapping the rest of the row edits it.
struct IntakeProposalRow: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let proposal: IntakeProposal
  /// A row in a job that is not waiting for review, or already applied.
  var isReadOnly = false
  var isHighlighted = false
  /// The existing row this proposal targets or looks like, when it has been read.
  var existing: Transaction?
  var accountCandidates: [SlipCandidate] = []
  var categoryCandidates: [SlipCandidate] = []
  var onToggle: () -> Void = {}
  var onOpen: () -> Void = {}
  var onWhy: () -> Void = {}
  var onViewExisting: () -> Void = {}
  var onMatchExisting: () -> Void = {}
  var onMakeNew: () -> Void = {}
  var onPickAccount: (String) -> Void = { _ in }
  var onPickAccountForAll: (String) -> Void = { _ in }
  var onPickCategory: (String) -> Void = { _ in }

  private var draft: TransactionDraft { proposal.draft }
  private var isAlreadyIn: Bool { proposal.kind == .alreadyIn }
  private var isActionable: Bool { !isReadOnly && !proposal.isApplied && !isAlreadyIn }
  private var confidence: IntakeConfidence { IntakeConfidence(proposal.confidence) }

  /// Can be ticked: complete, not applied, and the job is open for review.
  private var canTick: Bool {
    isActionable && !proposal.isIncomplete
  }

  private var isTicked: Bool {
    proposal.appliesOnApproval && !proposal.isIncomplete
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 0) {
        leadingControl
        Button(action: onOpen) {
          summary
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(isActionable ? "Opens the row to edit" : "")
        if !isAlreadyIn {
          Button(action: onWhy) {
            Image(systemName: "info.circle")
              .font(.body)
              .foregroundStyle(Theme.accent)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Why \(displayTitle)")
        }
      }
      controls
    }
    .padding(.horizontal, 8)
    .padding(.bottom, hasControls ? 8 : 0)
    .background(
      Theme.card.opacity(isAlreadyIn ? 0.7 : 1),
      in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    )
    .overlay {
      if isHighlighted {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
          .strokeBorder(Theme.accent, lineWidth: 2)
      }
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: Leading checkbox

  @ViewBuilder
  private var leadingControl: some View {
    if isAlreadyIn {
      Image(systemName: "checkmark.circle")
        .font(.title2)
        .foregroundStyle(Theme.inflow)
        .frame(width: 44, height: 56)
        .accessibilityHidden(true)
    } else if proposal.isApplied {
      Image(systemName: "checkmark.circle.fill")
        .font(.title2)
        .foregroundStyle(Theme.inflow)
        .frame(width: 44, height: 56)
        .accessibilityLabel("Applied")
    } else {
      Button(action: onToggle) {
        Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(canTick ? Theme.accent : Color.secondary)
          .frame(width: 44, height: 56)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canTick)
      .accessibilityLabel("Include \(displayTitle)")
      .accessibilityValue(isTicked ? "Included" : (canTick ? "Not included" : "Can’t be approved yet"))
    }
  }

  // MARK: Summary

  private var summary: some View {
    VStack(alignment: .leading, spacing: 4) {
      titleLine
      if proposal.kind == .edit {
        ForEach(changes) { change in
          Text(changeText(change))
            .font(.subheadline)
        }
        if let existing {
          Text("Existing: \(existingLine(existing))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else if isAlreadyIn {
        alreadyInLine
      } else {
        Text(detailLine)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      if proposal.kind == .possibleDuplicate {
        duplicateLine
      }
      if let reconciled = proposal.reasons.first(where: { $0.hasPrefix("Reconciled") }) {
        Label(reconciled, systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline)
          .foregroundStyle(Theme.uncategorised)
      }
      if let message = problem {
        Label(message, systemImage: "exclamationmark.circle")
          .font(.subheadline)
          .foregroundStyle(Theme.uncategorised)
      }
      if proposal.isApplied {
        Label("Applied", systemImage: "checkmark")
          .font(.subheadline)
          .foregroundStyle(Theme.inflow)
      } else if !isAlreadyIn {
        HStack(spacing: 6) {
          Circle()
            .fill(confidence.colour)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
          Text(confidence.word)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(confidence.colour)
        }
      }
    }
  }

  @ViewBuilder
  private var titleLine: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 2) {
        Text(displayTitle)
          .font(.body.weight(.semibold))
          .foregroundStyle(isAlreadyIn ? Color.secondary : Theme.textPrimary)
        amountView
      }
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(displayTitle)
          .font(.body.weight(.semibold))
          .foregroundStyle(isAlreadyIn ? Color.secondary : Theme.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        amountView
          .layoutPriority(1)
      }
    }
  }

  @ViewBuilder
  private var amountView: some View {
    if draft.amountMagnitudeMilli <= 0 {
      Text("No amount")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.uncategorised)
    } else {
      let signed = draft.signedMilliunits
      HStack(spacing: 6) {
        if proposal.kind == .edit, proposal.changedFields.contains(.amount), let old = existing?.amount ?? proposal.targetSnapshot?.amount {
          Text(money(old))
            .strikethrough()
            .foregroundStyle(.secondary)
        }
        Text(money(signed))
          .foregroundStyle(isAlreadyIn ? Color.secondary : Theme.amountColour(signed))
      }
      .font(.body.weight(.semibold))
      .monospacedDigit()
    }
  }

  private var alreadyInLine: some View {
    Text(alreadyInText)
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var duplicateLine: some View {
    if let existing {
      Text("Looks like \(existingLine(existing, includeAmount: true)) already in \(existing.accountName)")
        .font(.subheadline)
        .foregroundStyle(Theme.textPrimary)
    } else if let reason = proposal.reasons.first {
      Text(reason)
        .font(.subheadline)
        .foregroundStyle(Theme.textPrimary)
    }
  }

  // MARK: Controls below the summary

  private var hasControls: Bool {
    isActionable || isAlreadyIn
  }

  @ViewBuilder
  private var controls: some View {
    if isAlreadyIn {
      if (existing ?? proposal.targetSnapshot) != nil {
        viewExistingButton
      }
    } else if isActionable {
      VStack(alignment: .leading, spacing: 4) {
        if proposal.kind == .add || proposal.kind == .possibleDuplicate {
          accountControl
          if draft.categoryID == nil {
            categoryControl
          }
        }
        if proposal.kind == .possibleDuplicate, existing != nil {
          viewExistingButton
        }
        if (proposal.kind == .add || proposal.kind == .possibleDuplicate), !proposal.candidateIDs.isEmpty {
          Button(action: onMatchExisting) {
            FilterChip(label: "Match to an existing transaction…", showsChevron: false)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if proposal.kind == .edit, proposal.flippedFrom != nil {
          Button(action: onMakeNew) {
            FilterChip(label: "Add as new instead", showsChevron: false)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.leading, 44)
    }
  }

  private var viewExistingButton: some View {
    Button(action: onViewExisting) {
      Text(isAlreadyIn ? "View in register" : "View existing")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.leading, 44)
  }

  /// A missing account shows the reader's candidates as chips, then every open
  /// account; a known one shows the account with a menu to change it, for this
  /// row or for the whole batch.
  @ViewBuilder
  private var accountControl: some View {
    if draft.accountID.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Which account?")
          .font(.footnote)
          .foregroundStyle(Theme.uncategorised)
        WrappingHStack(spacing: 8) {
          ForEach(accountCandidates.filter { candidate in model.openAccounts.contains { $0.id == candidate.id } }) { candidate in
            Button {
              onPickAccount(candidate.id)
            } label: {
              FilterChip(label: candidate.name, showsChevron: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          accountMenu(label: "Other account")
        }
      }
    } else {
      WrappingHStack(spacing: 8) {
        accountMenu(label: "Account: \(accountName)")
      }
    }
  }

  private func accountMenu(label: String) -> some View {
    Menu {
      ForEach(model.openAccounts) { account in
        Button {
          onPickAccount(account.id)
        } label: {
          if account.id == draft.accountID {
            Label(account.name, systemImage: "checkmark")
          } else {
            Text(account.name)
          }
        }
      }
      Menu("Use for all in this batch") {
        ForEach(model.openAccounts) { account in
          Button(account.name) {
            onPickAccountForAll(account.id)
          }
        }
      }
    } label: {
      FilterChip(label: label)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(label)
    .accessibilityHint("Choose the account for this row or the whole batch")
  }

  private var categoryControl: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("No category")
        .font(.footnote)
        .foregroundStyle(Theme.uncategorised)
      WrappingHStack(spacing: 8) {
        ForEach(categoryCandidates) { candidate in
          Button {
            onPickCategory(candidate.id)
          } label: {
            FilterChip(label: candidate.name, showsChevron: false)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        Menu {
          ForEach(model.categoryGroups.filter { !$0.deleted && !$0.hidden }) { group in
            let categories = group.categories.filter { !$0.deleted }
            if !categories.isEmpty {
              Menu(group.name) {
                ForEach(categories) { category in
                  Button(category.name) {
                    onPickCategory(category.id)
                  }
                }
              }
            }
          }
        } label: {
          FilterChip(label: categoryCandidates.isEmpty ? "Choose category" : "Other category")
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Choose category")
      }
    }
  }

  // MARK: Text

  private var accountName: String {
    model.accounts.first { $0.id == draft.accountID }?.name ?? "No account"
  }

  private var displayTitle: String {
    let draftPayee = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    if proposal.kind == .edit, !proposal.changedFields.contains(.payee),
       let payee = (existing ?? proposal.targetSnapshot)?.payeeName, !payee.isEmpty {
      return payee
    }
    return draftPayee.isEmpty ? "No payee" : draftPayee
  }

  private var categoryTitle: String {
    model.categoryName(forID: draft.categoryID) ?? "No category"
  }

  private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated))
  }

  private func shortDate(iso: String) -> String {
    Date(isoDateString: iso).map { shortDate($0) } ?? iso
  }

  private func money(_ milliunits: Int) -> String {
    MoneyCodec.displayString(for: milliunits, currencyFormat: model.currencyFormat)
  }

  /// "5 Oct · Eating Out · DBS Altitude".
  private var detailLine: String {
    "\(shortDate(draft.date)) · \(categoryTitle) · \(accountName)"
  }

  private func existingLine(_ row: Transaction, includeAmount: Bool = false) -> String {
    let payee = (row.payeeName ?? "").isEmpty ? "a transaction" : (row.payeeName ?? "")
    if includeAmount {
      return "\(shortDate(iso: row.date)) · \(payee) · \(money(row.amount))"
    }
    let category = model.categoryName(forID: row.categoryID) ?? row.categoryName ?? "Uncategorised"
    return "\(shortDate(iso: row.date)) · \(category) · \(row.accountName)"
  }

  private var alreadyInText: String {
    if let row = existing ?? proposal.targetSnapshot {
      return "Matches \(shortDate(iso: row.date)) in \(row.accountName)"
    }
    return "Already in the register"
  }

  /// What stops this row from being approved, or what went wrong applying it.
  private var problem: String? {
    if let issue = proposal.issue {
      return issue
    }
    guard isActionable else {
      return nil
    }
    if proposal.kind == .edit || proposal.kind == .alreadyIn {
      return proposal.targetTransactionID == nil ? "The original transaction is gone" : nil
    }
    if draft.amountMagnitudeMilli <= 0 {
      return "Couldn’t read an amount. Tap to add one. Approve skips it until then."
    }
    if draft.accountID.isEmpty {
      return "Choose an account to approve this row."
    }
    return nil
  }

  private struct Change: Identifiable {
    var label: String
    var old: String
    var new: String
    var id: String { label }
  }

  /// "Payee ~~Grab~~ → GrabFood": one wrapping run of text, old value struck through.
  private func changeText(_ change: Change) -> AttributedString {
    var label = AttributedString("\(change.label) ")
    label.foregroundColor = Color.secondary
    var old = AttributedString(change.old)
    old.strikethroughStyle = .single
    old.foregroundColor = Color.secondary
    var arrow = AttributedString(" → ")
    arrow.foregroundColor = Color.secondary
    var new = AttributedString(change.new)
    new.font = Font.subheadline.weight(.semibold)
    new.foregroundColor = Theme.textPrimary
    return label + old + arrow + new
  }

  /// Changed fields only, old value first. Amount is drawn beside the amount.
  private var changes: [Change] {
    guard proposal.kind == .edit else {
      return []
    }
    let snapshot = existing ?? proposal.targetSnapshot
    return proposal.changedFields.compactMap { field in
      switch field {
      case .payee:
        let old = snapshot?.payeeName ?? ""
        let new = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Change(label: field.label, old: old.isEmpty ? "No payee" : old, new: new.isEmpty ? "No payee" : new)
      case .category:
        let old = model.categoryName(forID: snapshot?.categoryID) ?? snapshot?.categoryName ?? "No category"
        return Change(label: field.label, old: old, new: categoryTitle)
      case .date:
        let old = snapshot.map { shortDate(iso: $0.date) } ?? "Unknown"
        return Change(label: field.label, old: old, new: shortDate(draft.date))
      case .memo:
        let old = snapshot?.memo ?? ""
        return Change(label: field.label, old: old.isEmpty ? "None" : old, new: draft.memo.isEmpty ? "None" : draft.memo)
      case .amount, .unknown:
        return nil
      }
    }
  }

  /// "Fix, Grab, GrabFood, minus $12.60, payee was Grab, Sure".
  private var spokenLabel: String {
    var parts = [proposal.kind.reviewWord, displayTitle]
    if proposal.kind != .edit, draft.categoryID != nil {
      parts.append(categoryTitle)
    }
    if draft.amountMagnitudeMilli > 0 {
      parts.append(spokenMoney(draft.signedMilliunits))
    } else {
      parts.append("no amount")
    }
    if proposal.kind == .edit {
      for field in proposal.changedFields {
        switch field {
        case .amount:
          if let old = (existing ?? proposal.targetSnapshot)?.amount {
            parts.append("was \(spokenMoney(old))")
          }
        case .unknown:
          break
        default:
          if let change = changes.first(where: { $0.label == field.label }) {
            parts.append("\(change.label.lowercased()) was \(change.old)")
          }
        }
      }
    } else if proposal.kind == .possibleDuplicate, let existing {
      parts.append("looks like \(existingLine(existing, includeAmount: true)) already in \(existing.accountName)")
    }
    if let message = problem {
      parts.append(message)
    }
    if proposal.isApplied {
      parts.append("applied")
    } else if proposal.kind != .alreadyIn {
      parts.append(confidence.word)
    }
    return parts.joined(separator: ", ")
  }

  /// "minus $12.60": the minus sign is spoken, not left to the symbol.
  private func spokenMoney(_ milliunits: Int) -> String {
    let text = money(abs(milliunits))
    return milliunits < 0 ? "minus \(text)" : text
  }
}
