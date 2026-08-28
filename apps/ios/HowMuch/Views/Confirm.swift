import SwiftUI

struct ConfirmButton {
  fileprivate let label: LocalizedStringKey
  fileprivate let role: ButtonRole?

  static func destructive(_ label: LocalizedStringKey) -> ConfirmButton {
    ConfirmButton(label: label, role: .destructive)
  }

  static func proceed(_ label: LocalizedStringKey) -> ConfirmButton {
    ConfirmButton(label: label, role: nil)
  }
}

extension View {
  func binaryConfirm<Item, Message: View>(
    _ title: LocalizedStringKey,
    presenting item: Binding<Item?>,
    confirm button: ConfirmButton,
    @ViewBuilder message: (Item) -> Message,
    action: @escaping (Item) -> Void
  ) -> some View {
    alert(
      title,
      isPresented: isPresented(for: item),
      presenting: item.wrappedValue
    ) { value in
      Button(button.label, role: button.role) { action(value) }
      Button("Cancel", role: .cancel) {}
    } message: { value in
      message(value)
    }
  }

  func binaryConfirm<Item>(
    _ title: LocalizedStringKey,
    presenting item: Binding<Item?>,
    confirm button: ConfirmButton,
    action: @escaping (Item) -> Void
  ) -> some View {
    alert(
      title,
      isPresented: isPresented(for: item),
      presenting: item.wrappedValue
    ) { value in
      Button(button.label, role: button.role) { action(value) }
      Button("Cancel", role: .cancel) {}
    }
  }

  func binaryConfirm<Message: View>(
    _ title: LocalizedStringKey,
    isPresented: Binding<Bool>,
    confirm button: ConfirmButton,
    @ViewBuilder message: () -> Message,
    action: @escaping () -> Void
  ) -> some View {
    alert(title, isPresented: isPresented) {
      Button(button.label, role: button.role) { action() }
      Button("Cancel", role: .cancel) {}
    } message: {
      message()
    }
  }

  func binaryConfirm(
    _ title: LocalizedStringKey,
    isPresented: Binding<Bool>,
    confirm button: ConfirmButton,
    action: @escaping () -> Void
  ) -> some View {
    alert(title, isPresented: isPresented) {
      Button(button.label, role: button.role) { action() }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func isPresented<Item>(for item: Binding<Item?>) -> Binding<Bool> {
    Binding(
      get: { item.wrappedValue != nil },
      set: { presented in if !presented { item.wrappedValue = nil } }
    )
  }
}
