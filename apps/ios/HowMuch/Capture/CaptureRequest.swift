import Foundation

struct CaptureRequest: Identifiable, Equatable {
  let id: UUID
  let connectionFingerprint: String?
  var kind: Kind

  enum Kind: Equatable {
    case blank
    case draft(TransactionDraft)
    case inbox
  }

  init(
    id: UUID = UUID(),
    kind: Kind,
    connectionFingerprint: String?
  ) {
    self.id = id
    self.kind = kind
    self.connectionFingerprint = connectionFingerprint
  }
}

enum CaptureAdmission: Equatable {
  case drop
  case present(CaptureRequest)
  case inbox

  static func decide(
    _ request: CaptureRequest,
    isAuthenticated: Bool,
    currentFingerprint: String
  ) -> CaptureAdmission {
    guard isAuthenticated else {
      return .drop
    }
    if let fingerprint = request.connectionFingerprint, fingerprint != currentFingerprint {
      return .drop
    }
    if case .inbox = request.kind {
      return .inbox
    }
    return .present(request)
  }
}
