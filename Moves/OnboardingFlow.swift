import SwiftData
import SwiftUI

/// First-launch pages shown only when the timeline is empty.
///
/// Presented as a full-screen cover so it does not stack on the location
/// permission banners. Motion is not requested here.
struct OnboardingFlow: View {
    var onRequestLocation: () -> Void
    var onImportGoogle: () -> Void
    var onImportFiles: () -> Void
    var onSkip: () -> Void

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                OnboardingPage(
                    symbolName: "calendar",
                    title: String(localized: "Your private timeline"),
                    message: String(localized: "Moves records where you went, how you got there, and how long you stayed. Your timeline is saved on this iPhone and, when iCloud is on, in your private iCloud.")
                )
                .tag(0)

                OnboardingPage(
                    symbolName: "location.circle",
                    title: String(localized: "Location, quietly"),
                    message: String(localized: "Always location lets Moves notice arrivals and departures. It uses the low-power visit monitor, not GPS.")
                )
                .tag(1)

                OnboardingPage(
                    symbolName: "clock.arrow.circlepath",
                    title: String(localized: "Bring your history"),
                    message: String(localized: "Import Google Timeline, or GPS files from another app. Apple Health workout routes are in Settings.")
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            VStack(spacing: 12) {
                if page == 1 {
                    Button(String(localized: "Allow Location Access")) {
                        onRequestLocation()
                        page = 2
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if page == 2 {
                    Button(String(localized: "Google Timeline")) {
                        onImportGoogle()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(String(localized: "GPS files")) {
                        onImportFiles()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button(String(localized: "Continue")) {
                        page = 1
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button(page == 2 ? String(localized: "Skip") : String(localized: "Not now")) {
                    onSkip()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .padding(.top, 8)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

private struct OnboardingPage: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: symbolName)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(MovesPalette.routeTracking)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

enum OnboardingStorage {
    static let hasSeenKey = "moves.hasSeenOnboarding"
}
