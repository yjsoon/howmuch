import SwiftUI
import UIKit

extension View {
  /// White rounded card, the basic YNAB surface.
  func ynabCard() -> some View {
    background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  func flagRail(_ colour: Color?) -> some View {
    overlay(alignment: .trailing) {
      if let colour {
        Rectangle()
          .fill(colour)
          .frame(width: 3)
          .accessibilityHidden(true)
      }
    }
  }
}

/// Form row with a leading icon that shows a caption + value once filled,
/// or just a placeholder before that.
struct DisclosureValueRow: View {
  let icon: String
  let caption: String
  let value: String?
  var placeholder: String
  /// Card layouts draw this trailing chevron. Form and List `NavigationLink`s
  /// already supply one, so pass `false` there or the row shows a double `>`.
  var showsChevron = true

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(Theme.accent)
        .frame(width: 28)

      if let value, !value.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(value)
            .foregroundStyle(Theme.textPrimary)
        }
      } else {
        Text(placeholder)
          .foregroundStyle(Theme.textPrimary.opacity(0.75))
      }

      Spacer(minLength: 0)

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, showsChevron ? 16 : 0)
    .padding(.vertical, showsChevron ? 13 : 0)
    .contentShape(Rectangle())
  }
}

/// Divider aligned past the leading icon column of `DisclosureValueRow`.
struct CardDivider: View {
  var body: some View {
    Divider().padding(.leading, 56)
  }
}

/// Wraps chips onto another line instead of compressing them off-screen.
struct WrappingHStack: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(in: proposal.width ?? 0, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let origins = arrange(in: bounds.width, subviews: subviews).origins
    for (subview, origin) in zip(subviews, origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: .unspecified
      )
    }
  }

  private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if width > 0, x > 0, x + size.width > width {
        x = 0
        y += rowHeight + lineSpacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      rowHeight = max(rowHeight, size.height)
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
    }

    return (CGSize(width: usedWidth, height: y + rowHeight), origins)
  }
}

/// Capsule used by Reflect filter menus and scope pickers.
struct FilterChip: View {
  let label: String
  var isActive = false
  var showsChevron = true

  var body: some View {
    HStack(spacing: 5) {
      Text(label)
        .font(.footnote.weight(.medium))
      if showsChevron {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(isActive ? Theme.card : Theme.accent)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceMuted), in: Capsule())
  }
}

/// `‹ June 2026 ›` month stepper, clamped to the current month.
struct MonthStepper: View {
  @Binding var monthAnchor: Date

  var body: some View {
    HStack {
      stepButton(systemName: "chevron.left", monthDelta: -1)
      Spacer()
      Text(monthAnchor.monthYearLabel)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
      Spacer()
      stepButton(systemName: "chevron.right", monthDelta: 1)
        .disabled(isCurrentMonth)
        .opacity(isCurrentMonth ? 0.3 : 1)
    }
    .padding(.horizontal, 8)
  }

  private var isCurrentMonth: Bool {
    monthAnchor.startOfMonth() >= Date.now.startOfMonth()
  }

  private func stepButton(systemName: String, monthDelta: Int) -> some View {
    Button {
      if let next = Calendar.current.date(byAdding: .month, value: monthDelta, to: monthAnchor) {
        monthAnchor = next
      }
    } label: {
      Image(systemName: systemName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(8)
        .background(Theme.surfaceMuted, in: Circle())
    }
    .buttonStyle(.plain)
  }
}

enum AppTab: Hashable, CaseIterable {
  case accounts
  case rewards
  case reflect
  case plan
  case assistant

  static let compactDestinations: [AppTab] = [.accounts, .rewards, .reflect]

  var isCompactDestination: Bool {
    Self.compactDestinations.contains(self)
  }

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .rewards: return "Rewards"
    case .reflect: return "Reflect"
    case .plan: return "Plan"
    case .assistant: return "Assistant"
    }
  }

  var systemImage: String {
    switch self {
    case .accounts: return "building.columns"
    case .rewards: return "creditcard"
    case .reflect: return "chart.bar.fill"
    case .plan: return "square.grid.2x2"
    case .assistant: return "bubble.left.and.bubble.right"
    }
  }

  var captureSurface: CaptureSurface {
    switch self {
    case .accounts: return .accounts
    case .rewards: return .rewards
    case .reflect: return .reflect
    case .plan: return .plan
    case .assistant: return .assistant
    }
  }

  var overflowDestination: MoreDestination? {
    switch self {
    case .plan: return .plan
    case .assistant: return .assistant
    case .accounts, .rewards, .reflect: return nil
    }
  }

  var compactBarSelection: CompactBarSelection? {
    switch self {
    case .accounts: return .accounts
    case .rewards: return .rewards
    case .reflect: return .reflect
    case .plan, .assistant: return nil
    }
  }
}

enum CompactBarSelection: Hashable {
  case accounts
  case rewards
  case reflect
  case addTransactions

  var tab: AppTab? {
    switch self {
    case .accounts: return .accounts
    case .rewards: return .rewards
    case .reflect: return .reflect
    case .addTransactions: return nil
    }
  }
}

enum RootTrailingAction {
  case addTransactions
  case assistant

  var title: String {
    switch self {
    case .addTransactions: return "Add Transactions"
    case .assistant: return "Assistant"
    }
  }

  var systemImage: String {
    switch self {
    case .addTransactions: return "plus.bubble"
    case .assistant: return "bubble.left.and.bubble.right"
    }
  }
}

enum MoreDestination: Hashable, CaseIterable, Identifiable {
  case plan
  case assistant

  var id: Self { self }

  var title: String {
    switch self {
    case .plan: return "Plan"
    case .assistant: return "Assistant"
    }
  }

  var systemImage: String {
    switch self {
    case .plan: return "square.grid.2x2"
    case .assistant: return "bubble.left.and.bubble.right"
    }
  }

  var captureSurface: CaptureSurface {
    switch self {
    case .plan: return .plan
    case .assistant: return .assistant
    }
  }

  var tab: AppTab {
    switch self {
    case .plan: return .plan
    case .assistant: return .assistant
    }
  }

  static func menuItems(omitting: MoreDestination?) -> [MoreDestination] {
    allCases.filter { $0 != omitting }
  }

  static func overflowItems(
    usesSidebar: Bool,
    omitting: MoreDestination?
  ) -> [MoreDestination] {
    guard !usesSidebar else {
      return []
    }
    return menuItems(omitting: omitting)
  }
}

enum RootChrome {
  static func usesSidebar(
    idiom: UIUserInterfaceIdiom,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> Bool {
    idiom == .pad && horizontalSizeClass == .regular
  }

  static func addControlInsets(
    idiom: UIUserInterfaceIdiom,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> EdgeInsets {
    if usesSidebar(idiom: idiom, horizontalSizeClass: horizontalSizeClass) {
      return EdgeInsets(top: 0, leading: 0, bottom: 28, trailing: 20)
    }
    return EdgeInsets(top: 0, leading: 0, bottom: 90, trailing: 16)
  }

  static func toastBottomPadding(
    idiom: UIUserInterfaceIdiom,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    if usesSidebar(idiom: idiom, horizontalSizeClass: horizontalSizeClass) {
      return 28 + RootAddControl.diameter + 8
    }
    return 90
  }
}

@MainActor
@Observable
final class RootChromeState {
  var tab: AppTab = .accounts {
    didSet {
      if tab.isCompactDestination {
        lastCompactTab = tab
      }
    }
  }
  private var lastCompactTab: AppTab = .accounts
  private var overflowByTab: [AppTab: MoreDestination] = [:]

  func overflow(on tab: AppTab) -> MoreDestination? {
    overflowByTab[tab]
  }

  func openMore(_ destination: MoreDestination) {
    if overflowByTab[tab] == destination {
      return
    }
    overflowByTab[tab] = destination
  }

  func dismissMore() {
    overflowByTab[tab] = nil
  }

  func adoptSidebarLayout() {
    guard let overflow = overflow(on: tab) else {
      return
    }
    overflowByTab[tab] = nil
    tab = overflow.tab
  }

  func adoptCompactLayout() {
    guard let destination = tab.overflowDestination else {
      return
    }
    tab = lastCompactTab
    openMore(destination)
  }

  /// Compact TabView only hosts Accounts / Rewards / Reflect. Plan and Assistant
  /// stay in More overlays, so the bar selection must never be those values.
  var compactBarTab: AppTab {
    tab.isCompactDestination ? tab : lastCompactTab
  }

  var captureSurface: CaptureSurface {
    if tab.isCompactDestination, let overflow = overflowByTab[tab] {
      return overflow.captureSurface
    }
    return tab.captureSurface
  }
}

/// Applies chrome inside the hosted view body. TabView drops modifiers
/// attached to `Tab` content, which otherwise crashes DestinationsMenu.
struct RootChromeScope<Content: View>: View {
  var chrome: RootChromeState
  var content: Content

  init(chrome: RootChromeState, @ViewBuilder content: () -> Content) {
    self.chrome = chrome
    self.content = content()
  }

  var body: some View {
    content.environment(chrome)
  }
}

/// Phone and iPad need separate TabView trees. `sidebarAdaptable` plus a
/// selection that is not in the current tab set fatal-errors on launch.
struct RootTabView: View {
  @Environment(AppModel.self) private var model
  @Bindable var chrome: RootChromeState
  var usesSidebar: Bool
  var workspace: CaptureWorkspace = .shared
  var presenting: (() -> Void)?
  var presentingManually: (() -> Void)?

  var body: some View {
    if usesSidebar {
      TabView(selection: $chrome.tab) {
        Tab(AppTab.accounts.title, systemImage: AppTab.accounts.systemImage, value: AppTab.accounts) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .accounts) {
              AccountsView()
            }
          }
        }
        Tab(AppTab.rewards.title, systemImage: AppTab.rewards.systemImage, value: AppTab.rewards) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .rewards) {
              NavigationStack {
                RewardsView()
              }
            }
          }
        }
        Tab(AppTab.reflect.title, systemImage: AppTab.reflect.systemImage, value: AppTab.reflect) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .reflect) {
              NavigationStack {
                ReflectView()
              }
            }
          }
        }
        Tab(AppTab.plan.title, systemImage: AppTab.plan.systemImage, value: AppTab.plan) {
          RootChromeScope(chrome: chrome) {
            NavigationStack {
              CategoriesView()
            }
          }
        }
        Tab(AppTab.assistant.title, systemImage: AppTab.assistant.systemImage, value: AppTab.assistant) {
          RootChromeScope(chrome: chrome) {
            NavigationStack {
              AssistantView(workspace: workspace)
            }
          }
        }
      }
      .tabViewStyle(.sidebarAdaptable)
      .defaultAdaptableTabBarPlacement(.sidebar)
    } else {
      TabView(selection: compactBarSelection) {
        Tab(AppTab.accounts.title, systemImage: AppTab.accounts.systemImage, value: CompactBarSelection.accounts) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .accounts) {
              AccountsView()
            }
          }
        }
        Tab(AppTab.rewards.title, systemImage: AppTab.rewards.systemImage, value: CompactBarSelection.rewards) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .rewards) {
              NavigationStack {
                RewardsView()
              }
            }
          }
        }
        Tab(AppTab.reflect.title, systemImage: AppTab.reflect.systemImage, value: CompactBarSelection.reflect) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .reflect) {
              NavigationStack {
                ReflectView()
              }
            }
          }
        }
        RootCaptureTab(addManually: presentManual)
      }
      .tabViewStyle(.tabBarOnly)
      .tabBarMinimizeBehavior(.onScrollDown)
      .background {
        RootTabBarTrailingActions(
          addManually: presentManual,
          openAssistant: { chrome.openMore(.assistant) }
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
  }

  private var compactBarSelection: Binding<CompactBarSelection> {
    Binding(
      get: { chrome.compactBarTab.compactBarSelection ?? .accounts },
      set: { selection in
        if selection == .addTransactions {
          presentCapture()
          return
        }
        if let tab = selection.tab {
          chrome.tab = tab
        }
      }
    )
  }

  private func presentCapture() {
    if let presenting {
      presenting()
      return
    }
    model.presentAddTransactions(origin: model.addTransactionsOrigin())
  }

  private func presentManual() {
    if let presentingManually {
      presentingManually()
      return
    }
    model.presentManualTransaction(origin: model.addTransactionsOrigin())
  }
}

struct RootCaptureTab: TabContent {
  let addManually: () -> Void

  var body: some TabContent<CompactBarSelection> {
    Tab(
      RootTrailingAction.addTransactions.title,
      systemImage: RootTrailingAction.addTransactions.systemImage,
      value: CompactBarSelection.addTransactions,
      role: .search
    ) {
      Color.clear
    }
    .contextMenu {
      Button("Add manually", systemImage: "square.and.pencil", action: addManually)
    }
  }
}

/// SwiftUI's TabContent menu serves the sidebar, not the iPhone tab bar.
struct RootTabBarTrailingActions: UIViewControllerRepresentable {
  var addManually: () -> Void
  var openAssistant: () -> Void

  func makeUIViewController(context: Context) -> Controller {
    let controller = Controller()
    controller.addManually = addManually
    controller.openAssistant = openAssistant
    return controller
  }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.addManually = addManually
    controller.openAssistant = openAssistant
    controller.install()
  }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
      controller.stopTracking()
      controller.uninstall()
    }

  final class Controller: UIViewController, UIContextMenuInteractionDelegate {
    var addManually: () -> Void = {}
    var openAssistant: () -> Void = {}
    private weak var target: UIView?
    private var menuInteraction: UIContextMenuInteraction?
    private var manualAction: UIAccessibilityCustomAction?
    private var assistantButton: UIButton?
    private var attachedManualTargets: [NSObject] = []
    private var displayLink: CADisplayLink?
    private weak var hostedBar: UITabBar?
    private weak var reservedCluster: UIView?
    private weak var destinationPlatter: UIView?
    private var originalClusterMargins: NSDirectionalEdgeInsets?
    private var reservedWidth: CGFloat = 0
    private var destinationShift: CGFloat = 0

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      startTracking()
      install()
    }

    override func viewDidDisappear(_ animated: Bool) {
      stopTracking()
      super.viewDidDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      install()
    }

    func install() {
      guard let window = view.window else {
        return
      }
      let accounts = tabRowView(AppTab.accounts.title, in: window)
      let addView = accounts.flatMap { searchRoleAdd(in: window, alignedWith: $0) }
        ?? rightmostCompactView(inBottomBandOf: window)
      guard let addView else {
        return
      }
      startTracking()
      let tabBar = hostedTabBar()
      if addView !== target {
        uninstall()
        target = addView
        hostedBar = tabBar
        if addView.accessibilityLabel == nil || addView.accessibilityLabel?.isEmpty == true {
          addView.accessibilityLabel = RootTrailingAction.addTransactions.title
        }
        let interaction = UIContextMenuInteraction(delegate: self)
        menuInteraction = interaction
        addView.addInteraction(interaction)
      }
      attachManualEntryAction(in: window, preferring: addView)
      hostedBar = tabBar
      layoutAssistant(
        relativeTo: addView,
        alignedWith: accounts ?? addView,
        tabBar: tabBar,
        in: window
      )
    }

    func uninstall() {
      if let menuInteraction { target?.removeInteraction(menuInteraction) }
      if let manualAction {
        for object in attachedManualTargets {
          object.accessibilityCustomActions = object.accessibilityCustomActions?.filter { $0 !== manualAction }
        }
      }
      attachedManualTargets = []
      assistantButton?.removeFromSuperview()
      restoreReservation()
      target = nil
      menuInteraction = nil
      manualAction = nil
      assistantButton = nil
      hostedBar = nil
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        UIMenu(children: [
          UIAction(title: "Add manually", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.addManually()
          },
        ])
      }
    }

    private func layoutAssistant(
      relativeTo add: UIView,
      alignedWith _: UIView,
      tabBar: UITabBar?,
      in window: UIWindow
    ) {
      let host = hostForAssistant(add: add, window: window)
      let pin = circularPin(from: add, in: window)
      let button = assistantButton ?? makeAssistantButton()
      if button.superview !== host {
        button.removeFromSuperview()
        host.addSubview(button)
      }
      assistantButton = button
      button.tintColor = tabBar?.tintColor ?? window.tintColor

      let gap: CGFloat = 8
      let pinInHost = pin.convert(pin.bounds, to: host)
      let side = max(44, min(pinInHost.width, pinInHost.height))
      let size = CGSize(width: side, height: side)
      let needed = size.width + gap
      shiftDestinationCapsule(in: window, excluding: pin, width: needed)
      let frame = CGRect(
        x: pinInHost.minX - gap - size.width,
        y: pinInHost.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
      let suppress = CaptureRouter.shared.hidesTabRowOverlay
      button.isHidden = suppress
      button.layer.cornerRadius = size.height / 2
      button.clipsToBounds = true
      button.frame = frame
      if suppress {
        return
      }
      host.bringSubviewToFront(button)
    }

    private func makeAssistantButton() -> UIButton {
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(systemName: RootTrailingAction.assistant.systemImage)
      configuration.baseForegroundColor = .label
      configuration.background.backgroundColor = .white.withAlphaComponent(0.92)
      configuration.cornerStyle = .capsule
      button.configuration = configuration
      button.accessibilityLabel = RootTrailingAction.assistant.title
      button.accessibilityTraits = .button
      button.isAccessibilityElement = true
      button.addAction(UIAction { [weak self] _ in
        self?.openAssistant()
      }, for: .touchUpInside)
      button.addAction(UIAction { [weak self] _ in
        self?.openAssistant()
      }, for: .primaryActionTriggered)
      return button
    }

    private func restoreReservation() {
      if let reservedCluster, let originalClusterMargins {
        reservedCluster.directionalLayoutMargins = originalClusterMargins
      }
      if let hostedBar {
        for title in AppTab.compactDestinations.map(\.title) {
          labelledControl(title, in: hostedBar)?.transform = .identity
        }
        hostedBar.transform = .identity
      }
      destinationPlatter?.transform = .identity
      reservedCluster = nil
      originalClusterMargins = nil
      destinationPlatter = nil
      reservedWidth = 0
      destinationShift = 0
    }

    private func reserveLane(add: UIView, reflect: UIView, width: CGFloat) {
      guard let tabBar = hostedBar,
            let cluster = destinationCluster(reflect: reflect, add: add, tabBar: tabBar) else {
        return
      }
      if reservedCluster == nil {
        reservedCluster = cluster
        originalClusterMargins = cluster.directionalLayoutMargins
      }
      reservedWidth = max(reservedWidth, width)
      var margins = originalClusterMargins ?? cluster.directionalLayoutMargins
      margins.trailing = (originalClusterMargins?.trailing ?? margins.trailing) + reservedWidth
      cluster.directionalLayoutMargins = margins
      (cluster as? UIStackView)?.isLayoutMarginsRelativeArrangement = true
    }

    private func shiftDestinations(in tabBar: UITabBar, excluding add: UIView, width: CGFloat) {
      destinationShift = max(destinationShift, width)
      for title in AppTab.compactDestinations.map(\.title) {
        guard let control = labelledControl(title, in: tabBar), control !== add else {
          continue
        }
        control.transform = CGAffineTransform(translationX: -destinationShift, y: 0)
      }
    }

    private func hostedTabBar() -> UITabBar? {
      if let root = view.window?.rootViewController, let tab = tabController(in: root) {
        return tab.tabBar
      }
      guard let window = view.window else {
        return nil
      }
      return firstTabBar(in: window)
    }

    private func firstTabBar(in view: UIView) -> UITabBar? {
      if let bar = view as? UITabBar {
        return bar
      }
      return view.subviews.lazy.compactMap { self.firstTabBar(in: $0) }.first
    }

    private func destinationCluster(reflect: UIView, add: UIView, tabBar: UITabBar) -> UIView? {
      var cluster: UIView?
      var current: UIView? = reflect.superview
      while let view = current, view !== tabBar {
        if add.isDescendant(of: view) {
          break
        }
        cluster = view
        current = view.superview
      }
      return cluster
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
      if let tab = controller as? UITabBarController { return tab }
      return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    private func shiftDestinationCapsule(in window: UIWindow, excluding add: UIView, width: CGFloat) {
      destinationShift = max(destinationShift, width)
      let bandMinY = window.bounds.maxY - 160
      var capsule: UIView?
      var capsuleWidth: CGFloat = 0
      func walk(_ view: UIView) {
        if view !== add, !add.isDescendant(of: view) {
          let frame = view.convert(view.bounds, to: window)
          let inBand = frame.midY >= bandMinY
          let shape = frame.width >= 180 && frame.width <= 360 && frame.height >= 48 && frame.height <= 88
          if inBand, shape, frame.width > capsuleWidth {
            capsule = view
            capsuleWidth = frame.width
          }
        }
        for subview in view.subviews {
          walk(subview)
        }
      }
      walk(window)
      guard let capsule else {
        return
      }
      destinationPlatter = capsule
      capsule.transform = CGAffineTransform(translationX: -destinationShift, y: 0)
    }

    private func destinationCluster(reflect: UIView, add: UIView, stopAt ancestor: UIView?) -> UIView? {
      var cluster: UIView?
      var current: UIView? = reflect.superview
      while let view = current, view !== ancestor, view !== add.window {
        if add.isDescendant(of: view) {
          break
        }
        cluster = view
        current = view.superview
      }
      return cluster
    }

    private func attachManualEntryAction(in window: UIWindow, preferring view: UIView) {
      let title = RootTrailingAction.addTransactions.title
      if view.accessibilityLabel == nil || view.accessibilityLabel?.isEmpty == true {
        view.accessibilityLabel = title
      }
      let action = manualAction ?? UIAccessibilityCustomAction(name: "Add manually") { [weak self] _ in
        guard let self else { return false }
        self.addManually()
        return true
      }
      manualAction = action
      applyManualEntry(action, to: view)
      applyManualEntry(action, to: circularPin(from: view, in: window))
      var seen = Set<ObjectIdentifier>()
      func walk(_ object: NSObject) {
        let identity = ObjectIdentifier(object)
        guard !seen.contains(identity) else { return }
        seen.insert(identity)
        if object.accessibilityLabel == title {
          applyManualEntry(action, to: object)
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
          for index in 0..<count {
            if let element = object.accessibilityElement(at: index) as? NSObject {
              walk(element)
            }
          }
        } else if let elements = object.accessibilityElements {
          for element in elements {
            if let child = element as? NSObject {
              walk(child)
            }
          }
        }
        if let host = object as? UIView {
          for subview in host.subviews {
            walk(subview)
          }
        }
      }
      walk(window)
    }

    private func startTracking() {
      guard displayLink == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(onDisplayTick))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    func stopTracking() {
      displayLink?.invalidate()
      displayLink = nil
    }

    @objc private func onDisplayTick() {
      install()
    }

    private func applyManualEntry(_ action: UIAccessibilityCustomAction, to object: NSObject) {
      let existing = object.accessibilityCustomActions ?? []
      if existing.contains(where: { $0 === action || $0.name == "Add manually" }) {
        if !attachedManualTargets.contains(where: { $0 === object }) {
          attachedManualTargets.append(object)
        }
        return
      }
      object.accessibilityCustomActions = existing + [action]
      attachedManualTargets.append(object)
    }

    private func hostForAssistant(add: UIView, window: UIWindow) -> UIView {
      window
    }

    /// iOS 26's search-role pin is often an inner image; walk up to the visible circle.
    private func circularPin(from view: UIView, in window: UIWindow) -> UIView {
      var pin = view
      var current = view.superview
      while let parent = current {
        if parent === assistantButton { break }
        let frame = parent.convert(parent.bounds, to: window)
        let compact = abs(frame.width - frame.height) <= 14 && frame.width >= 40 && frame.width <= 80
        if compact {
          pin = parent
          current = parent.superview
        } else {
          break
        }
      }
      return pin
    }

    private func searchRoleAdd(in window: UIWindow, alignedWith accounts: UIView) -> UIView? {
      let title = RootTrailingAction.addTransactions.title
      let rowY = accounts.convert(accounts.bounds, to: window).midY
      let labelled = labelledViews(title, in: window).filter { view in
        abs(view.convert(view.bounds, to: window).midY - rowY) <= 28
      }
      if let add = labelled.max(by: { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX }) {
        return add
      }
      let accountsFrame = accounts.convert(accounts.bounds, to: window)
      let destinations = Set(AppTab.compactDestinations.map(\.title) + [RootTrailingAction.assistant.title])
      var candidates: [UIView] = []
      func walk(_ view: UIView) {
        if view !== accounts, view !== assistantButton {
          let frame = view.convert(view.bounds, to: window)
          let aligned = abs(frame.midY - rowY) <= 28
          let trailing = frame.minX > accountsFrame.maxX + 8
          let compact = abs(frame.width - frame.height) <= 14 && frame.width >= 40 && frame.width <= 76
          let label = view.accessibilityLabel ?? ""
          if aligned, trailing, compact, !destinations.contains(label) {
            candidates.append(view)
          }
        }
        for subview in view.subviews {
          walk(subview)
        }
      }
      walk(window)
      let controls = candidates.compactMap { $0 as? UIControl }
      let pool = controls.isEmpty ? candidates : controls
      let roots = pool.filter { candidate in
        !pool.contains { $0 !== candidate && candidate.isDescendant(of: $0) }
      }
      return roots.max { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX }
    }

    private func rightmostCompactView(inBottomBandOf window: UIWindow) -> UIView? {
      let bandMinY = window.bounds.maxY - 160
      var candidates: [UIView] = []
      func walk(_ view: UIView) {
        guard view !== assistantButton else { return }
        let frame = view.convert(view.bounds, to: window)
        let inBand = frame.midY >= bandMinY && frame.maxY <= window.bounds.maxY - 8
        let compact = abs(frame.width - frame.height) <= 14 && frame.width >= 40 && frame.width <= 76
        if inBand, compact {
          candidates.append(view)
        }
        for subview in view.subviews {
          walk(subview)
        }
      }
      walk(window)
      let controls = candidates.compactMap { $0 as? UIControl }
      let pool = controls.isEmpty ? candidates : controls
      let roots = pool.filter { candidate in
        !pool.contains { $0 !== candidate && candidate.isDescendant(of: $0) }
      }
      return roots.max { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX }
    }

    private func tabRowView(_ label: String, in window: UIWindow) -> UIView? {
      labelledViews(label, in: window)
        .filter { $0.convert($0.bounds, to: window).midY > window.bounds.midY }
        .max { $0.convert($0.bounds, to: window).midY < $1.convert($1.bounds, to: window).midY }
    }

    private func labelledViews(_ label: String, in view: UIView) -> [UIView] {
      var matches: [UIView] = []
      if view.accessibilityLabel == label {
        matches.append(view)
      }
      for subview in view.subviews {
        matches.append(contentsOf: labelledViews(label, in: subview))
      }
      return matches
    }

    private func tabRowControl(_ label: String, in window: UIWindow) -> UIControl? {
      tabRowView(label, in: window) as? UIControl
    }

    private func labelledControl(_ label: String, in view: UIView) -> UIControl? {
      labelledControls(label, in: view).first
    }

    private func labelledControls(_ label: String, in view: UIView) -> [UIControl] {
      labelledViews(label, in: view).compactMap { $0 as? UIControl }
    }
  }
}

struct RootTabHost<Content: View>: View {
  @Environment(RootChromeState.self) private var chrome
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let hostedTab: AppTab
  var content: Content

  init(for hostedTab: AppTab, @ViewBuilder content: () -> Content) {
    self.hostedTab = hostedTab
    self.content = content()
  }

  var body: some View {
    let usesSidebar = RootChrome.usesSidebar(
      idiom: UIDevice.current.userInterfaceIdiom,
      horizontalSizeClass: horizontalSizeClass
    )
    let overflow = usesSidebar ? nil : chrome.overflow(on: hostedTab)
    ZStack {
      content
        .allowsHitTesting(overflow == nil)
        .accessibilityHidden(overflow != nil)
      if let overflow {
        RootMoreHost(destination: overflow)
          .transition(.move(edge: .trailing))
      }
    }
    .animation(.snappy, value: overflow)
  }
}

struct RootMoreHost: View {
  @Environment(RootChromeState.self) private var chrome
  let destination: MoreDestination

  var body: some View {
    NavigationStack {
      destinationRoot
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              chrome.dismissMore()
            } label: {
              Label(chrome.tab.title, systemImage: "chevron.left")
            }
            .accessibilityLabel("Back")
          }
        }
    }
    .background(Theme.canvas)
  }

  @ViewBuilder
  private var destinationRoot: some View {
    switch destination {
    case .plan:
      CategoriesView()
    case .assistant:
      AssistantView(workspace: CaptureWorkspace.shared)
    }
  }
}

struct RootAddControl: View {
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome
  var workspace: CaptureWorkspace = .shared
  var presenting: (() -> Void)?
  var presentingManually: (() -> Void)?

  static let diameter: CGFloat = 56

  var body: some View {
    if isVisible {
      button
    }
  }

  private var isVisible: Bool {
    !(chrome.captureSurface == .assistant && workspace.pendingAssistantSessionID != nil)
  }

  private var button: some View {
    Button(action: addConversationally) {
      Image(systemName: "plus")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: Self.diameter, height: Self.diameter)
        .background(Theme.accent, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add Transactions")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Add manually", addManually)
    .contextMenu {
      Button("Add manually", systemImage: "square.and.pencil", action: addManually)
    }
    .frame(minWidth: 44, minHeight: 44)
  }

  private func addConversationally() {
    if let presenting {
      presenting()
      return
    }
    model.presentAddTransactions(origin: model.addTransactionsOrigin())
  }

  private func addManually() {
    if let presentingManually {
      presentingManually()
      return
    }
    model.presentManualTransaction(origin: model.addTransactionsOrigin())
  }
}

struct DestinationsMenu: View {
  var omitting: MoreDestination?
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    let overflowItems = MoreDestination.overflowItems(
      usesSidebar: RootChrome.usesSidebar(
        idiom: UIDevice.current.userInterfaceIdiom,
        horizontalSizeClass: horizontalSizeClass
      ),
      omitting: omitting
    )
    Menu {
      if !overflowItems.isEmpty {
        ForEach(overflowItems) { destination in
          Button {
            chrome.openMore(destination)
          } label: {
            Label(destination.title, systemImage: destination.systemImage)
          }
        }
        Divider()
      }
      Button {
        model.isShowingSettings = true
      } label: {
        Label("Connection settings", systemImage: "gearshape")
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .tint(Theme.accent)
    .accessibilityLabel("More")
  }
}

/// Loading / error placeholder for a surface driven by a `LoadPhase`.
struct PhasePlaceholder: View {
  let phase: LoadPhase
  let retry: @MainActor () async -> Void

  var body: some View {
    VStack(spacing: 12) {
      switch phase {
      case .loading, .idle:
        ProgressView()
      case .failed(let message):
        Image(systemName: "wifi.exclamationmark")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Retry") {
          Task { await retry() }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
      case .loaded:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

/// Horizontal stacked bar showing each segment's share of a whole.
struct StackedShareBar: View {
  let segments: [(colour: Color, fraction: Double)]
  var height: CGFloat = 14

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(segments.enumerated(), id: \.offset) { _, segment in
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(segment.colour)
            .frame(width: max(4, proxy.size.width * segment.fraction))
        }
      }
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
  }
}

/// Shared x-axis row so net worth and income charts label months the same way.
private struct ChartAxisLabels: View {
  let labels: [String]
  var spacing: CGFloat = 6

  var body: some View {
    let visible = visibleIndices
    HStack(alignment: .top, spacing: spacing) {
      ForEach(labels.indices, id: \.self) { index in
        let isVisible = visible.contains(index)
        Text(isVisible ? labels[index] : " ")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.65)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(!isVisible)
      }
    }
  }

  /// About twelve ticks. If a window contains a year-bearing label
  /// (`Jan 26`), show that rather than the window start, so All Time
  /// does not drop the year boundary.
  private var visibleIndices: Set<Int> {
    let count = labels.count
    guard count > 0 else { return [] }
    let stride = max(1, Int(ceil(Double(count) / 12)))
    var visible: Set<Int> = [count - 1]
    var start = 0
    while start < count {
      let end = min(start + stride, count)
      if let yearTick = (start ..< end).first(where: carriesYear) {
        visible.insert(yearTick)
      } else {
        visible.insert(start)
      }
      start += stride
    }
    return visible
  }

  private func carriesYear(_ index: Int) -> Bool {
    labels[index].range(of: #"\s\d{2}$"#, options: .regularExpression) != nil
  }
}

/// Single-series column chart drawn with capsules; negatives drop below the axis.
struct ColumnChart: View {
  let values: [Double]
  var labels: [String] = []
  var positiveColour: Color = Theme.accent
  var negativeColour: Color = Theme.outflow
  var height: CGFloat = 90

  private let monthSpacing: CGFloat = 6

  var body: some View {
    let magnitude = max(values.map(abs).max() ?? 1, 1)
    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: monthSpacing) {
        ForEach(values.enumerated(), id: \.offset) { _, value in
          VStack(spacing: 0) {
            Spacer(minLength: 0)
            Capsule()
              .fill(value < 0 ? negativeColour : positiveColour)
              .frame(height: max(3, height * abs(value) / magnitude))
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: height)

      if labels.count == values.count, !labels.isEmpty {
        ChartAxisLabels(labels: labels, spacing: monthSpacing)
      }
    }
  }
}

/// Paired income/spending columns per period.
struct PairedColumnChart: View {
  let pairs: [(income: Double, spending: Double)]
  var labels: [String] = []
  var height: CGFloat = 90

  private let monthSpacing: CGFloat = 10

  var body: some View {
    let magnitude = max(pairs.flatMap { [$0.income, $0.spending] }.max() ?? 1, 1)

    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: monthSpacing) {
        ForEach(pairs.enumerated(), id: \.offset) { _, pair in
          HStack(alignment: .bottom, spacing: 2) {
            Capsule()
              .fill(Theme.inflow)
              .frame(height: max(3, height * pair.income / magnitude))
            Capsule()
              .fill(Theme.outflow)
              .frame(height: max(3, height * pair.spending / magnitude))
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: height)

      if labels.count == pairs.count, !labels.isEmpty {
        ChartAxisLabels(labels: labels, spacing: monthSpacing)
      }
    }
  }
}

/// Simple line sparkline for a small trend.
struct Sparkline: View {
  let values: [Double]
  var colour: Color = Theme.accent
  var height: CGFloat = 56

  var body: some View {
    GeometryReader { proxy in
      let lowest = values.min() ?? 0
      let highest = values.max() ?? 1
      let span = max(highest - lowest, 0.001)
      let points = values.enumerated().map { index, value in
        CGPoint(
          x: values.count > 1 ? proxy.size.width * CGFloat(index) / CGFloat(values.count - 1) : proxy.size.width / 2,
          y: proxy.size.height * (1 - CGFloat((value - lowest) / span))
        )
      }
      ZStack {
        Path { path in
          guard let first = points.first else { return }
          path.move(to: first)
          for point in points.dropFirst() {
            path.addLine(to: point)
          }
        }
        .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        if let last = points.last {
          Circle()
            .fill(colour)
            .frame(width: 6, height: 6)
            .position(last)
        }
      }
    }
    .frame(height: height)
  }
}
