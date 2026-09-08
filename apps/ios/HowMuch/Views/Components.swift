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

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .rewards: return "Rewards"
    case .reflect: return "Reflect"
    }
  }

  var systemImage: String {
    switch self {
    case .accounts: return "building.columns"
    case .rewards: return "creditcard"
    case .reflect: return "chart.bar.fill"
    }
  }

  var captureSurface: CaptureSurface {
    switch self {
    case .accounts: return .accounts
    case .rewards: return .rewards
    case .reflect: return .reflect
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

  static func menuItems(omitting: MoreDestination?) -> [MoreDestination] {
    allCases.filter { $0 != omitting }
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
    let clearance = usesSidebar(idiom: idiom, horizontalSizeClass: horizontalSizeClass) ? 28.0 : 90.0
    return clearance + RootAddControl.diameter + 8
  }
}

@MainActor
@Observable
final class RootChromeState {
  var tab: AppTab = .accounts
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

  var captureSurface: CaptureSurface {
    overflowByTab[tab]?.captureSurface ?? tab.captureSurface
  }
}

struct RootTabHost<Content: View>: View {
  @Environment(RootChromeState.self) private var chrome
  let hostedTab: AppTab
  var content: Content

  init(for hostedTab: AppTab, @ViewBuilder content: () -> Content) {
    self.hostedTab = hostedTab
    self.content = content()
  }

  var body: some View {
    let overflow = chrome.overflow(on: hostedTab)
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
    if chrome.overflow(on: chrome.tab) == .assistant, workspace.pendingAssistantSessionID != nil {
      return false
    }
    return true
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

  var body: some View {
    Menu {
      ForEach(MoreDestination.menuItems(omitting: omitting)) { destination in
        Button {
          chrome.openMore(destination)
        } label: {
          Label(destination.title, systemImage: destination.systemImage)
        }
      }
      Divider()
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
