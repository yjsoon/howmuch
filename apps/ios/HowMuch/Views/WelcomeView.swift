import SwiftUI
import UIKit

/// First run: keep the ledger on this device, or sign in to a server.
struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @State private var isStarting = false
  @State private var errorMessage: String?

  private let device = UIDevice.current.model

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      VStack(spacing: 12) {
        Image("BrandIcon")
          .resizable()
          .scaledToFit()
          .frame(width: 80, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .accessibilityHidden(true)
        Text("Halation")
          .font(.largeTitle.bold())
          .foregroundStyle(Theme.textPrimary)
        Text("Track what you spend, account by account.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 32)
      Spacer()
      VStack(spacing: 16) {
        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(Theme.outflow)
            .multilineTextAlignment(.center)
        }
        Button(action: start) {
          HStack(spacing: 8) {
            if isStarting {
              ProgressView()
                .tint(.white)
            }
            Text("Start on this \(device)")
          }
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(isStarting)
        .accessibilityIdentifier("welcome-start-local")

        Text("Your records stay on this \(device). No sign-in needed.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Button("Connect to a server") {
          model.showConnectionFromWelcome()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44)
        .disabled(isStarting)
        .accessibilityIdentifier("welcome-connect-server")
      }
      .frame(maxWidth: 420)
      .padding(.horizontal, 24)
      .padding(.bottom, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.canvas.ignoresSafeArea())
  }

  private func start() {
    isStarting = true
    errorMessage = nil
    Task {
      do {
        try await model.startOnThisDevice()
      } catch {
        errorMessage = "Couldn’t set up this \(device). \(error.localizedDescription)"
      }
      isStarting = false
    }
  }
}
