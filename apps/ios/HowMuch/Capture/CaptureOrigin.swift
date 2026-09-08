import Foundation

/// How a capture session was admitted. Frozen on the request and session;
/// later navigation must not rebind it.
enum CaptureOrigin: Equatable, Codable, Sendable {
  /// + from a specific account register.
  case visibleRegister(accountID: String)
  /// + from overview, Rewards, Assistant, Plan, or Reflect.
  case lastUsedOpen
  /// Home Screen Add Expense quick action. Ignores a leftover visible register.
  case homeScreenShortcut
  /// Duplicate, structured App Intent, or other preset draft.
  case presetDraft
  /// Share, screenshot offer, or inbox App Intent.
  case inbox

  var usesLastUsedOpenAccount: Bool {
    switch self {
    case .lastUsedOpen, .homeScreenShortcut, .inbox:
      return true
    case .visibleRegister, .presetDraft:
      return false
    }
  }

  var ignoresVisibleRegister: Bool {
    switch self {
    case .homeScreenShortcut, .lastUsedOpen, .inbox, .presetDraft:
      return true
    case .visibleRegister:
      return false
    }
  }
}

/// Frozen account context for one admitted session. The selector and the
/// interpreter both read this value.
struct CaptureAccountContext: Equatable, Codable, Sendable {
  var selectedAccountID: String?
  var origin: CaptureOrigin
  /// True when the user must pick an account before anything can inherit one.
  var needsAccountChoice: Bool { selectedAccountID == nil }

  static func resolve(
    origin: CaptureOrigin,
    openAccounts: [Account],
    lastUsedAccountID: String?,
    focusedRegisterAccountID: String? = nil,
    presetAccountID: String? = nil
  ) -> CaptureAccountContext {
    // Visible-register leftover is never a silent fallback. Only
    // `.visibleRegister` may use a register account, and that id lives on
    // the origin itself.
    _ = focusedRegisterAccountID
    let open = openAccounts.filter { !$0.closed && !$0.deleted }
    let openIDs = Set(open.map(\.id))

    func valid(_ id: String?) -> String? {
      guard let id, openIDs.contains(id) else {
        return nil
      }
      return id
    }

    let selected: String?
    switch origin {
    case .visibleRegister(let accountID):
      selected = valid(accountID) ?? valid(lastUsedAccountID) ?? open.first?.id
    case .homeScreenShortcut, .lastUsedOpen, .inbox:
      selected = valid(lastUsedAccountID) ?? open.first?.id
    case .presetDraft:
      selected = valid(presetAccountID) ?? valid(lastUsedAccountID) ?? open.first?.id
    }

    return CaptureAccountContext(selectedAccountID: selected, origin: origin)
  }
}

enum CaptureSurface: Hashable, Sendable {
  case accounts
  case rewards
  case assistant
  case plan
  case reflect
}

enum CaptureAdmissionGate {
  static func canAdmit(referencePhase: LoadPhase) -> Bool {
    switch referencePhase {
    case .loaded, .failed:
      return true
    case .idle, .loading:
      return false
    }
  }

  static func shouldRefreshReference(phase: LoadPhase, explicitRetry: Bool) -> Bool {
    if explicitRetry {
      return true
    }
    return phase == .idle
  }

  static func shouldAdmitAfterRefresh(
    request: CaptureRequest,
    presented: CaptureRequest?,
    isCancelled: Bool,
    settingsScopeKey: String?,
    workspaceScopeKey: String?
  ) -> Bool {
    !isCancelled
      && presented?.id == request.id
      && settingsScopeKey == workspaceScopeKey
  }
}

enum CaptureEntryMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case describe
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .describe:
      return "Describe"
    case .manual:
      return "Manual"
    }
  }
}
