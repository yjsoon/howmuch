import Observation
import SwiftUI

@MainActor
@Observable
final class CaptureRouter {
  static let shared = CaptureRouter()

  var pending: CaptureRequest?
  var presented: CaptureRequest?
  private(set) var blockingSheetCount = 0

  /// One rule for compact chrome: a capture session or any blocking sheet
  /// hides the destination pill, circular Add, and the window-level Assistant.
  var hidesTabRowOverlay: Bool {
    presented != nil || pending != nil || blockingSheetCount > 0
  }

  private init() {}

  func enqueue(_ request: CaptureRequest) {
    if case .inbox = request.kind {
      if case .inbox = pending?.kind {
        return
      }
      if case .inbox = presented?.kind {
        return
      }
    }
    pending = request
  }

  func beginBlockingSheet() {
    blockingSheetCount += 1
  }

  func endBlockingSheet() {
    blockingSheetCount = max(0, blockingSheetCount - 1)
  }

  func consume(isAuthenticated: Bool, currentFingerprint: String) {
    guard let request = pending else {
      return
    }
    switch CaptureAdmission.decide(
      request,
      isAuthenticated: isAuthenticated,
      currentFingerprint: currentFingerprint
    ) {
    case .drop:
      pending = nil
      return
    case .inbox:
      guard blockingSheetCount == 0 else {
        return
      }
      pending = nil
      presented = request
    case .present(let admitted):
      guard blockingSheetCount == 0 else {
        return
      }
      pending = nil
      presented = admitted
    }
  }

  func dropForSignOut() {
    pending = nil
    presented = nil
  }
}

struct CaptureBlockingSheetModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .onAppear {
        CaptureRouter.shared.beginBlockingSheet()
      }
      .onDisappear {
        CaptureRouter.shared.endBlockingSheet()
      }
  }
}

extension View {
  func blocksCapturePresentation() -> some View {
    modifier(CaptureBlockingSheetModifier())
  }
}
