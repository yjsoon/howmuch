import SwiftUI

struct AccountIdentityFields: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var name: String
  @Binding var classification: AccountClassification
  @Binding var icon: AccountIconChoice
  var nameFocus: FocusState<Bool>.Binding
  var onSubmitName: (() -> Void)? = nil
  @State private var isPickingIcon = false

  init(
    name: Binding<String>,
    classification: Binding<AccountClassification>,
    icon: Binding<AccountIconChoice>,
    nameFocus: FocusState<Bool>.Binding,
    onSubmitName: (() -> Void)? = nil
  ) {
    _name = name
    _classification = classification
    _icon = icon
    self.nameFocus = nameFocus
    self.onSubmitName = onSubmitName
  }

  init(
    name: Binding<String>,
    kind: Binding<AccountKind>,
    icon: Binding<AccountIconChoice>,
    nameFocus: FocusState<Bool>.Binding,
    onSubmitName: (() -> Void)? = nil
  ) {
    self.init(
      name: name,
      classification: Binding(
        get: { .kind(kind.wrappedValue) },
        set: { if case .kind(let next) = $0 { kind.wrappedValue = next } }
      ),
      icon: icon,
      nameFocus: nameFocus,
      onSubmitName: onSubmitName
    )
  }

  var body: some View {
    Group {
      nameCard
      typeCard
      iconCard
    }
  }

  private var shownIcon: AccountIcon {
    icon.resolved(default: classification.defaultIcon)
  }

  private var nameCard: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
        }
      } else {
        HStack {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .ynabCard()
  }

  private var nameField: some View {
    TextField(classification.kind?.placeholderName ?? "Account name", text: $name)
      .textInputAutocapitalization(.words)
      .focused(nameFocus)
      .submitLabel(onSubmitName == nil ? .done : .next)
      .onSubmit { onSubmitName?() }
  }

  private var typeCard: some View {
    NavigationLink {
      AccountKindPicker(selection: $classification)
    } label: {
      HStack {
        Text("Type")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(classification.defaultIcon.rawValue)
          .font(.title3)
          .accessibilityHidden(true)
        Text(classification.title)
          .foregroundStyle(.secondary)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .ynabCard()
    .accessibilityLabel("Type")
    .accessibilityValue(classification.title)
    .accessibilityHint("Opens the account type list")
  }

  private var iconCard: some View {
    Button {
      nameFocus.wrappedValue = false
      isPickingIcon = true
    } label: {
      HStack {
        Text("Icon")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(shownIcon.rawValue)
          .font(.title3)
          .accessibilityHidden(true)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .ynabCard()
    .accessibilityLabel("Icon")
    .accessibilityValue(shownIcon.rawValue)
    .accessibilityHint("Opens the icon picker")
    .sheet(isPresented: $isPickingIcon) {
      AccountIconPicker(selected: shownIcon) { picked in
        icon = .custom(picked)
        isPickingIcon = false
      }
    }
  }
}

private struct AccountKindPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: AccountClassification

  var body: some View {
    List {
      ForEach(AccountKind.Group.allCases) { group in
        Section {
          ForEach(AccountKind.kinds(in: group)) { kind in
            Button {
              selection = .kind(kind)
              dismiss()
            } label: {
              HStack(spacing: 12) {
                Text(kind.defaultIcon.rawValue)
                  .font(.title3)
                  .frame(width: 32)
                  .accessibilityHidden(true)
                Text(kind.title)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                if selection == .kind(kind) {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                }
              }
            }
            .accessibilityLabel(kind.title)
            .accessibilityAddTraits(selection == .kind(kind) ? [.isSelected] : [])
          }
        } header: {
          Text(group.title)
        } footer: {
          Text(group.footer)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Account Type")
    .navigationBarTitleDisplayMode(.inline)
  }
}
