import Observation
import SwiftUI

/// Shared capture admission queue and blocking-sheet counter.
/// Compact chrome hides while a capture is pending/presented or any
/// `blocksCapturePresentation` sheet is counted (`blockingSheetCount > 0`).
@MainActor
@Observable
final class CaptureRouter {
  static let shared = CaptureRouter()

  var pending: CaptureRequest?
  var presented: CaptureRequest?
  private(set) var blockingSheetCount = 0

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
  @State private var isCounting = false

  func body(content: Content) -> some View {
    content
      .onAppear { sync(true) }
      .onDisappear { sync(false) }
  }

  private func sync(_ presented: Bool) {
    if presented {
      guard !isCounting else { return }
      isCounting = true
      CaptureRouter.shared.beginBlockingSheet()
    } else {
      guard isCounting else { return }
      isCounting = false
      CaptureRouter.shared.endBlockingSheet()
    }
  }
}

struct CaptureBlockingPresentedModifier: ViewModifier {
  var isPresented: Bool
  @State private var isCounting = false

  func body(content: Content) -> some View {
    content
      .onChange(of: isPresented, initial: true) { _, presented in
        sync(presented)
      }
      .onDisappear { sync(false) }
  }

  private func sync(_ presented: Bool) {
    if presented {
      guard !isCounting else { return }
      isCounting = true
      CaptureRouter.shared.beginBlockingSheet()
    } else {
      guard isCounting else { return }
      isCounting = false
      CaptureRouter.shared.endBlockingSheet()
    }
  }
}

extension View {
  func blocksCapturePresentation() -> some View {
    modifier(CaptureBlockingSheetModifier())
  }

  /// Counts the presentation binding so an item replacement (same sheet,
  /// new identity) cannot drop `blockingSheetCount` to 0 mid-transition.
  func blocksCapturePresentation(when isPresented: Bool) -> some View {
    modifier(CaptureBlockingPresentedModifier(isPresented: isPresented))
  }
}
