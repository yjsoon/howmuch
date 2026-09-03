import Observation
import SwiftUI

@MainActor
@Observable
final class CaptureRouter {
  static let shared = CaptureRouter()

  var pending: CaptureRequest?
  var presented: CaptureRequest?
  private(set) var blockingSheetCount = 0

  private init() {}

  func enqueue(_ request: CaptureRequest) {
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
    case .drop, .inbox:
      pending = nil
      return
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
