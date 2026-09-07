import Foundation

struct CaptureRequest: Identifiable, Equatable {
  let id: UUID
  let connectionFingerprint: String?
  var kind: Kind
  var origin: CaptureOrigin

  enum Kind: Equatable {
    case blank
    case draft(TransactionDraft)
    case inbox
  }

  init(
    id: UUID = UUID(),
    kind: Kind,
    connectionFingerprint: String?,
    origin: CaptureOrigin? = nil
  ) {
    self.id = id
    self.kind = kind
    self.connectionFingerprint = connectionFingerprint
    if let origin {
      self.origin = origin
    } else {
      switch kind {
      case .blank:
        self.origin = .lastUsedOpen
      case .draft:
        self.origin = .presetDraft
      case .inbox:
        self.origin = .inbox
      }
    }
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
