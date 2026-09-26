import SwiftUI
import UIKit

extension View {
  /// White rounded card, the basic YNAB surface.
  func ynabCard() -> some View {
    background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
  }

  /// Numbers that roll digit by digit when `value` changes. Under Reduce
  /// Motion the new figure simply replaces the old one.
  func rollingNumber(_ value: Int) -> some View {
    modifier(RollingNumber(value: value))
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

private struct RollingNumber: ViewModifier {
  let value: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
      .animation(reduceMotion ? nil : Theme.Motion.standard, value: value)
  }
}

/// Tappable cards and tiles sink slightly under the finger, so a tap that
/// pushes a screen or opens a sheet has visible touch-down feedback.
/// Avoid it on whole `List`/`Form` rows, which draw their own highlight.
struct PressableButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

extension ButtonStyle where Self == PressableButtonStyle {
  static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Rows stacked inside a `ynabCard()` highlight in place, like a List row,
/// instead of shrinking away from their neighbours.
struct CardRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        if configuration.isPressed {
          Theme.surfaceMuted
        }
      }
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

extension ButtonStyle where Self == CardRowButtonStyle {
  static var cardRow: CardRowButtonStyle { CardRowButtonStyle() }
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
    .animation(Theme.Motion.standard, value: isActive)
    .animation(Theme.Motion.standard, value: label)
  }
}

/// `‹ June 2026 ›` month stepper, clamped to the current month.
struct MonthStepper: View {
  @Binding var monthAnchor: Date
  /// Direction of the last step, so the label rolls the way the user moved.
  @State private var steppedBack = false
  @State private var steps = 0

  var body: some View {
    HStack {
      stepButton(systemName: "chevron.left", monthDelta: -1)
      Spacer()
      Text(monthAnchor.monthYearLabel)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .contentTransition(.numericText(countsDown: steppedBack))
        .animation(Theme.Motion.standard, value: monthAnchor)
      Spacer()
      stepButton(systemName: "chevron.right", monthDelta: 1)
        .disabled(isCurrentMonth)
        .opacity(isCurrentMonth ? 0.3 : 1)
        .animation(Theme.Motion.standard, value: isCurrentMonth)
    }
    .padding(.horizontal, 8)
    .sensoryFeedback(.selection, trigger: steps)
  }

  private var isCurrentMonth: Bool {
    monthAnchor.startOfMonth() >= Date.now.startOfMonth()
  }

  private func stepButton(systemName: String, monthDelta: Int) -> some View {
    Button {
      if let next = Calendar.current.date(byAdding: .month, value: monthDelta, to: monthAnchor) {
        steppedBack = monthDelta < 0
        steps += 1
        monthAnchor = next
      }
    } label: {
      Image(systemName: systemName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(8)
        .background(Theme.surfaceMuted, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.pressable)
  }
}

enum AppTab: Hashable, CaseIterable {
  case accounts
  case rewards
  case reflect
  case plan
  case assistant

  /// Compact destinations are the `CompactRootBar` triple — not an open-ended list.
  static var compactDestinations: [AppTab] { CompactRootBar.destinationTabs }

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

enum CompactBarSelection: Hashable, CaseIterable {
  case accounts
  case rewards
  case reflect
  case addTransaction

  var tab: AppTab? {
    switch self {
    case .accounts: return .accounts
    case .rewards: return .rewards
    case .reflect: return .reflect
    case .addTransaction: return nil
    }
  }

  var isDestination: Bool { tab != nil }
  var isAction: Bool { self == .addTransaction }
}

/// Compact iPhone chrome is structurally three destinations and one action button.
/// The destination triple is the capacity: a fourth tab is a type change, not an append.
enum CompactRootBar {
  static let destinationCapacity = 3
  static let actionCapacity = 1
  static let destinations: (AppTab, AppTab, AppTab) = (.accounts, .rewards, .reflect)
  static let action = RootTrailingAction.addTransaction
  static let actionSelection = CompactBarSelection.addTransaction

  static var destinationTabs: [AppTab] {
    let (first, second, third) = destinations
    return [first, second, third]
  }

  static var destinationSelections: [CompactBarSelection] {
    CompactBarSelection.allCases.filter(\.isDestination)
  }

  static var actionSelections: [CompactBarSelection] {
    CompactBarSelection.allCases.filter(\.isAction)
  }
}

enum RootTrailingAction: Equatable {
  case addTransaction
  case assistant

  var title: String {
    switch self {
    case .addTransaction: return "Add Transaction"
    case .assistant: return "Assistant"
    }
  }

  var systemImage: String {
    switch self {
    case .addTransaction: return "plus"
    case .assistant: return "plus.bubble"
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
  static let compactTabRowClearance: CGFloat = 90
  /// Space above the compact tab bar reserved for the floating Assistant.
  static let compactFloatingAssistantClearance = RootAddControl.diameter + 10
  static let compactToastGap: CGFloat = 12

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
    return EdgeInsets(top: 0, leading: 0, bottom: compactTabRowClearance, trailing: 16)
  }

  static func toastBottomPadding(
    idiom: UIUserInterfaceIdiom,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    if usesSidebar(idiom: idiom, horizontalSizeClass: horizontalSizeClass) {
      return 28 + RootAddControl.diameter + 8
    }
    return compactToastGap
  }
}

struct RootSaveToastOverlay: View {
  @Environment(AppModel.self) private var model
  var bottomPadding: CGFloat

  var body: some View {
    Group {
      if let message = model.lastSaveMessage {
        HStack(spacing: 8) {
          Image(systemName: message.kind == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(message.kind == .failure ? Theme.outflow : Theme.inflow)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
          Text(message.text)
            .foregroundStyle(message.kind == .failure ? Theme.outflow : Theme.textPrimary)
        }
        .font(.footnote.weight(.medium))
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, bottomPadding)
        .transition(
          .move(edge: .bottom)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.9, anchor: .bottom))
        )
      }
    }
    .animation(Theme.Motion.arrive, value: model.lastSaveMessage?.id)
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

  /// Cross-tab links between a Rewards card and its account register. The
  /// receiving tab consumes (clears) the request once it has acted on it.
  var pendingAccountID: String?
  var pendingRewardsCardID: String?

  func showAccount(_ accountID: String) {
    overflowByTab[.accounts] = nil
    pendingAccountID = accountID
    tab = .accounts
  }

  func showRewardsCard(_ cardID: String) {
    overflowByTab[.rewards] = nil
    pendingRewardsCardID = cardID
    tab = .rewards
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
  var presentingManually: (() -> Void)?

  var body: some View {
    if usesSidebar {
      TabView(selection: $chrome.tab) {
        Tab(AppTab.accounts.title, systemImage: AppTab.accounts.systemImage, value: AppTab.accounts) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .accounts, workspace: workspace) {
              AccountsView(usesSplit: usesSidebar)
            }
          }
        }
        Tab(AppTab.rewards.title, systemImage: AppTab.rewards.systemImage, value: AppTab.rewards) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .rewards, workspace: workspace) {
              NavigationStack {
                RewardsView()
              }
            }
          }
        }
        Tab(AppTab.reflect.title, systemImage: AppTab.reflect.systemImage, value: AppTab.reflect) {
          RootChromeScope(chrome: chrome) {
            RootTabHost(for: .reflect, workspace: workspace) {
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
        compactDestinationTab(CompactRootBar.destinations.0)
        compactDestinationTab(CompactRootBar.destinations.1)
        compactDestinationTab(CompactRootBar.destinations.2)
        RootCaptureTab()
      }
      .tabViewStyle(.tabBarOnly)
      .tabBarMinimizeBehavior(.onScrollDown)
      .overlay {
        RootTabBarFloatingAssistant(
          openAssistant: { chrome.openMore(.assistant) }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }

  @TabContentBuilder<CompactBarSelection>
  private func compactDestinationTab(_ tab: AppTab) -> some TabContent<CompactBarSelection> {
    Tab(tab.title, systemImage: tab.systemImage, value: tab.compactBarSelection ?? .accounts) {
      RootChromeScope(chrome: chrome) {
        RootTabHost(for: tab, workspace: workspace) {
          compactDestinationRoot(tab)
        }
      }
    }
  }

  @ViewBuilder
  private func compactDestinationRoot(_ tab: AppTab) -> some View {
    switch tab {
    case .accounts:
      AccountsView(usesSplit: usesSidebar)
    case .rewards:
      NavigationStack {
        RewardsView()
      }
    case .reflect:
      NavigationStack {
        ReflectView()
      }
    case .plan, .assistant:
      EmptyView()
    }
  }

  private var compactBarSelection: Binding<CompactBarSelection> {
    Binding(
      get: { chrome.compactBarTab.compactBarSelection ?? .accounts },
      set: { selection in
        if selection == CompactRootBar.actionSelection {
          presentManual()
          return
        }
        if let tab = selection.tab {
          chrome.tab = tab
        }
      }
    )
  }

  private func presentManual() {
    if let presentingManually {
      presentingManually()
      return
    }
    model.presentManualTransaction(origin: model.addTransactionsOrigin())
  }
}

/// The compact action stays separate from the destination pill.
struct RootCaptureTab: TabContent {
  private var role: TabRole {
    if #available(iOS 27.0, *) {
      // Search no longer guarantees the separate prominent treatment.
      return .prominent
    }
    return .search
  }

  var body: some TabContent<CompactBarSelection> {
    Tab(
      CompactRootBar.action.title,
      systemImage: CompactRootBar.action.systemImage,
      value: CompactRootBar.actionSelection,
      role: role
    ) {
      Color.clear
    }
  }
}

struct RootTabBarFloatingAssistant: UIViewControllerRepresentable {
  var openAssistant: () -> Void

  func makeUIViewController(context: Context) -> Controller {
    let controller = Controller()
    controller.openAssistant = openAssistant
    return controller
  }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.openAssistant = openAssistant
    controller.startTracking()
    controller.install()
  }

  static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
    controller.stopTracking()
    controller.uninstall()
  }

  final class Controller: UIViewController {
    var openAssistant: () -> Void = {}
    private var assistantButton: UIButton?
    private var displayLink: CADisplayLink?

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
      view.backgroundColor = .clear
      view.isAccessibilityElement = false
      view.accessibilityElementsHidden = true
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
      if CaptureRouter.shared.hidesTabRowOverlay {
        hideAssistant()
        return
      }
      guard let window = view.window else {
        return
      }
      // Hide when the tab-row Add pin is gone, not when a leftover system
      // UITabBarController.tabBar happens to be hidden.
      guard let addFrame = addPinFrame(in: window) else {
        hideAssistant()
        return
      }
      startTracking()
      layoutAssistant(relativeTo: addFrame, in: window)
    }

    func uninstall() {
      hideAssistant()
      assistantButton = nil
    }

    private func hideAssistant() {
      assistantButton?.isHidden = true
      assistantButton?.removeFromSuperview()
    }

    private func layoutAssistant(relativeTo pin: CGRect, in window: UIWindow) {
      let button = assistantButton ?? makeAssistantButton()
      assistantButton = button
      if CaptureRouter.shared.hidesTabRowOverlay {
        hideAssistant()
        return
      }
      if button.superview !== window {
        button.removeFromSuperview()
        window.addSubview(button)
      }
      button.tintColor = window.tintColor

      let gap: CGFloat = 10
      let side = max(44, min(max(pin.width, pin.height), 56))
      let size = CGSize(width: side, height: side)
      button.isHidden = false
      button.layer.cornerRadius = size.height / 2
      button.clipsToBounds = false
      button.frame = CGRect(
        x: pin.midX - size.width / 2,
        y: pin.minY - gap - size.height,
        width: size.width,
        height: size.height
      )
      window.bringSubviewToFront(button)
    }

    private func makeAssistantButton() -> UIButton {
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.glass()
      configuration.image = UIImage(systemName: RootTrailingAction.assistant.systemImage)
      configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      configuration.baseForegroundColor = .label
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

    func startTracking() {
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

    /// Same AX walk the snapshot tests use. iOS 26 tab buttons often exist only
    /// as accessibility elements, not as labelled UIView / UITabBar children.
    private func addPinFrame(in window: UIWindow) -> CGRect? {
      let pins = accessibilityPins(in: window)
      let accounts = pins.last { $0.label == AppTab.accounts.title && $0.frame.midY > window.bounds.midY }
        ?? pins.last { $0.label == AppTab.accounts.title }
      let addTitle = CompactRootBar.action.title
      let aligned = pins.filter { pin in
        pin.label == addTitle
          && (accounts.map { abs(pin.frame.midY - $0.frame.midY) <= 40 } ?? (pin.frame.midY > window.bounds.midY))
      }
      if let add = aligned.max(by: { $0.frame.minX < $1.frame.minX }) {
        return add.frame
      }
      return pins.last { $0.label == addTitle && $0.frame.midY > window.bounds.midY }?.frame
    }

    private struct AccessibilityPin {
      let label: String
      let frame: CGRect
    }

    private func accessibilityPins(in window: UIWindow) -> [AccessibilityPin] {
      var pins: [AccessibilityPin] = []
      var seen = Set<ObjectIdentifier>()
      func collect(_ object: NSObject) {
        let identity = ObjectIdentifier(object)
        guard !seen.contains(identity) else {
          return
        }
        seen.insert(identity)
        if object === assistantButton {
          return
        }
        if let view = object as? UIView, view.isHidden || view.alpha <= 0.01 {
          return
        }
        let label = object.accessibilityLabel ?? ""
        if !label.isEmpty,
           let frame = accessibilityFrame(of: object, in: window),
           frame.width > 1 || frame.height > 1,
           isExposed(object, frame: frame, in: window)
        {
          pins.append(AccessibilityPin(label: label, frame: frame))
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
          for index in 0..<count {
            if let element = object.accessibilityElement(at: index) as? NSObject {
              collect(element)
            }
          }
        } else if let elements = object.accessibilityElements {
          for element in elements {
            if let child = element as? NSObject {
              collect(child)
            }
          }
        }
        if let view = object as? UIView {
          for subview in view.subviews {
            collect(subview)
          }
        }
      }
      collect(window)
      return pins
    }

    /// Window-level AX objects are often neither `UIView` nor
    /// `UIAccessibilityElement`. The iOS SDK exposes `accessibilityContainer`
    /// on `UIAccessibilityElement`, not `NSObject`, so non-view nodes use a
    /// responds-to lookup. Drop a pin whose frame sits in a hidden tab bar
    /// that owns the row.
    private func isExposed(_ object: NSObject, frame: CGRect, in window: UIWindow) -> Bool {
      if !isExposedInContainerChain(object) {
        return false
      }
      if let owner = rowOwningTabBar(containing: frame, in: window), !isShownInHierarchy(owner) {
        return false
      }
      return true
    }

    private func isExposedInContainerChain(_ object: NSObject) -> Bool {
      var current: NSObject? = object
      var seen = Set<ObjectIdentifier>()
      while let node = current, !seen.contains(ObjectIdentifier(node)) {
        seen.insert(ObjectIdentifier(node))
        if let view = node as? UIView, view.isHidden || view.alpha <= 0.01 {
          return false
        }
        if let view = node as? UIView, let superview = view.superview {
          current = superview
          continue
        }
        current = accessibilityContainer(of: node)
      }
      return true
    }

    private func accessibilityContainer(of object: NSObject) -> NSObject? {
      if let element = object as? UIAccessibilityElement {
        return element.accessibilityContainer as? NSObject
      }
      let selector = NSSelectorFromString("accessibilityContainer")
      guard object.responds(to: selector) else {
        return nil
      }
      return object.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private func rowOwningTabBar(containing frame: CGRect, in window: UIWindow) -> UITabBar? {
      let owners = tabBars(in: window).filter { bar in
        bar.bounds.width > 1
          && bar.bounds.height > 1
          && bar.convert(bar.bounds, to: window).intersects(frame)
          && tabBarHostsRowLabelsIncludingHidden(bar)
      }
      return owners.first { isShownInHierarchy($0) } ?? owners.first
    }

    private func tabBars(in view: UIView) -> [UITabBar] {
      var found: [UITabBar] = []
      func walk(_ node: UIView) {
        if let bar = node as? UITabBar {
          found.append(bar)
        }
        for subview in node.subviews {
          walk(subview)
        }
      }
      walk(view)
      return found
    }

    private func tabBarHostsRowLabelsIncludingHidden(_ bar: UITabBar) -> Bool {
      var labels: Set<String> = []
      var seen = Set<ObjectIdentifier>()
      func collect(_ object: NSObject) {
        let identity = ObjectIdentifier(object)
        guard !seen.contains(identity) else {
          return
        }
        seen.insert(identity)
        if let label = object.accessibilityLabel, !label.isEmpty {
          labels.insert(label)
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
          for index in 0..<count {
            if let element = object.accessibilityElement(at: index) as? NSObject {
              collect(element)
            }
          }
        } else if let elements = object.accessibilityElements {
          for element in elements {
            if let child = element as? NSObject {
              collect(child)
            }
          }
        }
        if let view = object as? UIView {
          for subview in view.subviews {
            collect(subview)
          }
        }
      }
      collect(bar)
      return labels.contains(CompactRootBar.action.title) || labels.contains(AppTab.accounts.title)
    }

    private func isShownInHierarchy(_ view: UIView) -> Bool {
      var current: UIView? = view
      while let node = current {
        if node.isHidden || node.alpha <= 0.01 {
          return false
        }
        current = node.superview
      }
      return true
    }

    private func accessibilityFrame(of object: NSObject, in window: UIWindow) -> CGRect? {
      if let view = object as? UIView, view.bounds.width > 0 || view.bounds.height > 0 {
        return view.convert(view.bounds, to: window)
      }
      let screen = object.accessibilityFrame
      guard screen.width > 0 || screen.height > 0 else {
        return nil
      }
      return window.convert(screen, from: nil)
    }
  }
}

struct RootTabHost<Content: View>: View {
  @Environment(RootChromeState.self) private var chrome
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let hostedTab: AppTab
  var workspace: CaptureWorkspace = .shared
  var content: Content

  init(
    for hostedTab: AppTab,
    workspace: CaptureWorkspace = .shared,
    @ViewBuilder content: () -> Content
  ) {
    self.hostedTab = hostedTab
    self.workspace = workspace
    self.content = content()
  }

  var body: some View {
    let usesSidebar = RootChrome.usesSidebar(
      idiom: UIDevice.current.userInterfaceIdiom,
      horizontalSizeClass: horizontalSizeClass
    )
    let overflow = usesSidebar ? nil : chrome.overflow(on: hostedTab)
    let router = CaptureRouter.shared
    ZStack(alignment: .bottom) {
      ZStack {
        content
          .allowsHitTesting(overflow == nil)
          .accessibilityHidden(overflow != nil)
        if let overflow {
          RootMoreHost(destination: overflow, workspace: workspace)
            .transition(.move(edge: .trailing))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(Theme.Motion.standard, value: overflow)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !usesSidebar,
           !router.hidesTabRowOverlay,
           workspace.pendingAssistantSessionID == nil
        {
          Color.clear
            .frame(height: RootChrome.compactFloatingAssistantClearance)
            .accessibilityHidden(true)
        }
      }

      if !usesSidebar, hostedTab == chrome.compactBarTab {
        RootSaveToastOverlay(bottomPadding: RootChrome.compactToastGap)
      }
    }
  }
}

struct RootMoreHost: View {
  @Environment(RootChromeState.self) private var chrome
  let destination: MoreDestination
  var workspace: CaptureWorkspace = .shared

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
      AssistantView(workspace: workspace)
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

struct DestinationsMenu<Leading: View>: View {
  var omitting: MoreDestination?
  /// Screen-specific actions, shown as the first section.
  var leading: Leading
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(omitting: MoreDestination? = nil, @ViewBuilder leading: () -> Leading) {
    self.omitting = omitting
    self.leading = leading()
  }

  var body: some View {
    let overflowItems = MoreDestination.overflowItems(
      usesSidebar: RootChrome.usesSidebar(
        idiom: UIDevice.current.userInterfaceIdiom,
        horizontalSizeClass: horizontalSizeClass
      ),
      omitting: omitting
    )
    Menu {
      Section {
        leading
      }
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

extension DestinationsMenu where Leading == EmptyView {
  init(omitting: MoreDestination? = nil) {
    self.init(omitting: omitting) { EmptyView() }
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
    .animation(Theme.Motion.arrive, value: phase)
  }
}

/// Grows a chart from nothing the first time it appears. Reduce Motion shows
/// the finished chart straight away.
private struct ChartReveal: ViewModifier {
  @Binding var progress: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.onAppear {
      guard progress < 1 else { return }
      if reduceMotion {
        progress = 1
      } else {
        withAnimation(Theme.Motion.chart) {
          progress = 1
        }
      }
    }
  }
}

private extension View {
  func chartReveal(_ progress: Binding<CGFloat>) -> some View {
    modifier(ChartReveal(progress: progress))
  }
}

/// Thin capsule meter for one row's share of the largest row.
struct ShareMeter: View {
  let fraction: Double
  var colour: Color = Theme.accent
  @State private var progress: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Theme.surfaceMuted)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(colour)
            .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1) * progress))
        }
    }
    .animation(reduceMotion ? nil : Theme.Motion.chart, value: fraction)
    .chartReveal($progress)
    .accessibilityHidden(true)
  }
}

/// Horizontal stacked bar showing each segment's share of a whole.
struct StackedShareBar: View {
  let segments: [(colour: Color, fraction: Double)]
  var height: CGFloat = 14
  @State private var progress: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(segments.enumerated(), id: \.offset) { _, segment in
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(segment.colour)
            .frame(width: max(4, proxy.size.width * segment.fraction))
        }
      }
      .mask(alignment: .leading) {
        Rectangle()
          .frame(width: proxy.size.width * progress)
      }
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    .animation(reduceMotion ? nil : Theme.Motion.chart, value: segments.map { $0.fraction })
    .chartReveal($progress)
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

  @State private var progress: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Weekly ranges carry fifty-odd bars; tighter gaps keep them readable
  /// instead of spending the card's width on spacing.
  private var monthSpacing: CGFloat {
    switch values.count {
    case ..<19: 6
    case ..<37: 3
    default: 1
    }
  }

  var body: some View {
    let magnitude = max(values.map(abs).max() ?? 1, 1)
    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: monthSpacing) {
        ForEach(values.enumerated(), id: \.offset) { _, value in
          VStack(spacing: 0) {
            Spacer(minLength: 0)
            Capsule()
              .fill(value < 0 ? negativeColour : positiveColour)
              .frame(height: max(3, height * abs(value) / magnitude * progress))
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: height)
      .animation(reduceMotion ? nil : Theme.Motion.chart, value: values)
      .chartReveal($progress)

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

  @State private var progress: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Paired columns need more room per period, so they tighten sooner.
  private var monthSpacing: CGFloat {
    switch pairs.count {
    case ..<13: 10
    case ..<25: 5
    default: 2
    }
  }

  private var pairSpacing: CGFloat {
    pairs.count < 25 ? 2 : 1
  }

  var body: some View {
    let magnitude = max(pairs.flatMap { [$0.income, $0.spending] }.max() ?? 1, 1)

    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: monthSpacing) {
        ForEach(pairs.enumerated(), id: \.offset) { _, pair in
          HStack(alignment: .bottom, spacing: pairSpacing) {
            Capsule()
              .fill(Theme.inflow)
              .frame(height: max(3, height * pair.income / magnitude * progress))
            Capsule()
              .fill(Theme.outflow)
              .frame(height: max(3, height * pair.spending / magnitude * progress))
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: height)
      .animation(reduceMotion ? nil : Theme.Motion.chart, value: pairs.flatMap { [$0.income, $0.spending] })
      .chartReveal($progress)

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
  @State private var progress: CGFloat = 0

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
        .trim(from: 0, to: progress)
        .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        if let last = points.last {
          Circle()
            .fill(colour)
            .frame(width: 6, height: 6)
            .scaleEffect(progress)
            .opacity(Double(progress))
            .position(last)
        }
      }
    }
    .frame(height: height)
    .chartReveal($progress)
  }
}
