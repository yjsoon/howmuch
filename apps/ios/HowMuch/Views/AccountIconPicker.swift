import EmojiKit
import SwiftUI

struct AccountIconPicker: View {
  @Environment(\.dismiss) private var dismiss
  private let selected: AccountIcon?
  private let onPick: (AccountIcon) -> Void
  @State private var query = ""
  @State private var visibleCategory: EmojiCategory?
  @State private var gridSelection: Emoji.GridSelection?

  init(selected: AccountIcon?, onPick: @escaping (AccountIcon) -> Void) {
    self.selected = selected
    self.onPick = onPick

    if let selected {
      let emoji = Emoji(selected.rawValue)
      let categories = Self.liveCatalogue()
      let category = categories.category(withEmoji: emoji)
      _visibleCategory = State(initialValue: category ?? categories.first)
      _gridSelection = State(
        initialValue: category.map { Emoji.GridSelection(emoji: emoji, category: $0) }
      )
    } else {
      _visibleCategory = State(initialValue: Self.liveCatalogue().first)
      _gridSelection = State(initialValue: nil)
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        searchField
        if query.isEmpty {
          categoryJumpBar
        }
        EmojiGridScrollView(
          axis: .vertical,
          categories: displayedCategories,
          category: $visibleCategory,
          selection: $gridSelection,
          query: nil,
          action: handlePick,
          sectionTitle: themedSectionTitle,
          gridItem: themedGridItem
        )
        .emojiGridStyle(
          EmojiGridStyle(fontSize: 34, itemSpacing: 8, padding: 16, sectionSpacing: 20)
        )
        .scrollDismissesKeyboard(.interactively)
      }
      .padding(.top, 12)
      .background(Theme.canvas.ignoresSafeArea())
      .navigationTitle("Icon")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      .onChange(of: query) {
        visibleCategory = displayedCategories.first
        gridSelection = nil
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search emoji", text: $query)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundStyle(Theme.textPrimary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Theme.surfaceMuted, in: Capsule())
    .padding(.horizontal, 16)
  }

  private var categoryJumpBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(Self.liveCatalogue()) { category in
          let isVisible = visibleCategory?.id == category.id
          Button {
            visibleCategory = category
          } label: {
            Image(systemName: category.symbolIconName)
              .font(.body.weight(.semibold))
              .foregroundStyle(isVisible ? Theme.accent : Color.secondary)
              .frame(width: 38, height: 34)
              .background(
                isVisible ? Theme.accent.opacity(0.15) : Color.clear,
                in: Capsule()
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(category.labelText)
          .accessibilityAddTraits(isVisible ? .isSelected : [])
        }
      }
      .padding(.horizontal, 16)
    }
  }

  private var displayedCategories: [EmojiCategory] {
    query.isEmpty ? Self.liveCatalogue() : [Self.searchCategory(query)]
  }

  private static let standardCatalogue: [EmojiCategory] = {
    EmojiCategory.standardCategories.map(filtered(_:))
  }()

  private static func liveCatalogue() -> [EmojiCategory] {
    let frequent = filtered(EmojiCategory.frequent)
    if frequent.emojis.isEmpty {
      return standardCatalogue
    }
    return [frequent] + standardCatalogue
  }

  private static func filtered(_ category: EmojiCategory) -> EmojiCategory {
    let emojis = category.emojis
    let pickable = emojis.filter { AccountIcon(rawValue: $0.char) != nil }
    if pickable.count == emojis.count {
      return category
    }
    return .custom(
      id: category.id,
      name: category.labelText,
      emojis: pickable,
      iconName: category.symbolIconName
    )
  }

  private static func searchCategory(_ query: String) -> EmojiCategory {
    var seen = Set<String>()
    var emojis: [Emoji] = []

    if let icon = AccountIcon(rawValue: query) {
      seen.insert(icon.rawValue)
      emojis.append(Emoji(icon.rawValue))
    }

    for emoji in standardCatalogue.flatMap(\.emojis).matching(query) {
      if seen.insert(emoji.char).inserted {
        emojis.append(emoji)
      }
    }

    return .custom(id: "search", name: "Search", emojis: emojis)
  }

  private func handlePick(_ emoji: Emoji) {
    guard let icon = AccountIcon(rawValue: emoji.char) else { return }
    onPick(icon)
  }

  private func themedSectionTitle(
    _ parameters: Emoji.GridSectionTitleParameters
  ) -> some View {
    Text(parameters.category.labelText)
      .font(.headline)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func themedGridItem(
    _ parameters: Emoji.GridItemParameters
  ) -> some View {
    let isSelected = parameters.emoji.char == selected?.rawValue
    return Text(parameters.emoji.char)
      .frame(maxWidth: .infinity)
      .aspectRatio(1, contentMode: .fit)
      .background(
        isSelected ? Theme.accent.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous)
      )
      .accessibilityLabel(parameters.emoji.localizedName)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
