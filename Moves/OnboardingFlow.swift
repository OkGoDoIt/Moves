import HealthKit
import SwiftUI

/// First-launch pages shown only when the timeline is empty.
///
/// Presented as a full-screen cover so it does not stack on the location
/// permission banners. Motion is not requested here.
struct OnboardingFlow: View {
    var onRequestLocation: () -> Void
    var onImportGoogle: () -> Void
    var onImportPhotos: () -> Void
    var onImportHealth: () -> Void
    var onImportFiles: () -> Void
    var onSkip: () -> Void

    /// `MOVES_ONBOARDING_PAGE` lets screenshot agents open a later page without swiping.
    @State private var page = ProcessInfo.processInfo.environment["MOVES_ONBOARDING_PAGE"].flatMap(Int.init) ?? 0

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
                    message: String(localized: "Import Google Timeline, geotagged photos, Apple Health workouts, or GPS files.")
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
                    Button(action: onImportGoogle) {
                        importLabel(String(localized: "Google Timeline"), systemImage: "globe")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: onImportPhotos) {
                        importLabel(String(localized: "Photos"), systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if HKHealthStore.isHealthDataAvailable() {
                        Button(action: onImportHealth) {
                            importLabel(String(localized: "Apple Health"), systemImage: "figure.run")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button(action: onImportFiles) {
                        importLabel(String(localized: "GPS files"), systemImage: "square.and.arrow.down")
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

    private func importLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
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
