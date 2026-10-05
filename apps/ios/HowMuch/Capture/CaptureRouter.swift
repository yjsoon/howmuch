import Observation
import SwiftUI

@MainActor
@Observable
final class CaptureRouter {
  static let shared = CaptureRouter()

  var pending: CaptureRequest?
  var presented: CaptureRequest?
  private(set) var blockingSheetCount = 0
  private(set) var hidingTabBarCount = 0

  var hidesTabRowOverlay: Bool {
    presented != nil || pending != nil || blockingSheetCount > 0 || hidingTabBarCount > 0
  }

  /// Full-page form sheets opt into this so the compact Liquid Glass tab row
  /// is not left showing through iOS 26's inset sheet corners.
  var hidesCompactTabBar: Bool {
    hidingTabBarCount > 0
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

  func beginHidingTabBar() {
    hidingTabBarCount += 1
  }

  func endHidingTabBar() {
    hidingTabBarCount = max(0, hidingTabBarCount - 1)
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

/// Opaque HowMuch canvas for full-page form sheets. iOS 26's default sheet is
/// inset Liquid Glass with rounded corners on every edge; without this, the
/// compact tab row (and its circular Add control) shows through the bottom gap.
struct HowMuchFormSheet: ViewModifier {
  func body(content: Content) -> some View {
    content
      .presentationBackground(Theme.canvas)
      .onAppear {
        CaptureRouter.shared.beginHidingTabBar()
      }
      .onDisappear {
        CaptureRouter.shared.endHidingTabBar()
      }
  }
}

extension View {
  func blocksCapturePresentation() -> some View {
    modifier(CaptureBlockingSheetModifier())
  }

  func howmuchFormSheet() -> some View {
    modifier(HowMuchFormSheet())
  }
}
