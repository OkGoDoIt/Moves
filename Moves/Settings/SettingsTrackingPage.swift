//
//  SettingsTrackingPage.swift
//  Moves
//
//  Settings → Tracking: whether recording works, how detailed it is, background
//  recording, and the way into real route tracking.
//

import CoreLocation
import CoreMotion
import SwiftUI
import UIKit

struct TrackingSettingsPage: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var captureManager: MovesLocationCaptureManager

    @State private var motionStatus = CMMotionActivityManager.authorizationStatus()

    var body: some View {
        SettingsScrollPage("Tracking") {
            statusCard

            SettingsCard(title: String(localized: "Tracking Detail")) {
                ForEach(Array(CaptureDetailLevel.allCases.enumerated()), id: \.element) { index, level in
                    if index > 0 {
                        Divider()
                    }
                    detailOption(level)
                }
            }

            SettingsCard(title: String(localized: "Background")) {
                Toggle("Record in the background", isOn: listeningBinding)

                SettingsFootnote(String(localized: "Records your places and trips while Moves is closed."))
            }

            // Start and Stop right here; the stopping rules are one level down.
            RouteTrackingCard(captureManager: captureManager)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                motionStatus = CMMotionActivityManager.authorizationStatus()
            }
        }
    }

    // MARK: Status

    /// What the status card reads: live values, or in a debug build the
    /// `MOVES_TRACKING_PREVIEW` state, so every state can be seen in the simulator.
    private var inputs: TrackingStatusInputs {
        let live = TrackingStatusInputs(
            errorMessage: captureManager.lastErrorMessage,
            isDemoMode: captureManager.isDemoMode,
            authorization: captureManager.authorizationStatus,
            isPreciseLocation: !captureManager.isPreciseLocationOff,
            isBackgroundListeningEnabled: captureManager.isBackgroundLocationListeningEnabled,
            isRouteTrackingActive: isRouteTrackingActive,
            motion: motionStatus,
            trackingStatusText: captureManager.trackingStatusText
        )
        #if DEBUG
        if let preview = TrackingStatusInputs.preview(
            named: ProcessInfo.processInfo.environment["MOVES_TRACKING_PREVIEW"],
            from: live
        ) {
            return preview
        }
        #endif
        return live
    }

    private var status: TrackingStatusInputs.Status { inputs.status }

    private var motionIsOff: Bool { inputs.motionIsOff }
}

/// The Tracking page's status card as plain values, kept apart from the capture manager.
struct TrackingStatusInputs: Equatable {
    enum FixAction: Equatable {
        case allowLocation
        case openSettings
    }

    struct Status: Equatable {
        let title: String
        let message: String
        let systemImage: String
        let tint: Color
        var action: FixAction?
    }

    var errorMessage: String?
    var isDemoMode: Bool
    var authorization: CLAuthorizationStatus
    var isPreciseLocation: Bool
    var isBackgroundListeningEnabled: Bool
    var isRouteTrackingActive: Bool
    var motion: CMAuthorizationStatus
    var trackingStatusText: String

    #if DEBUG
    /// `MOVES_TRACKING_PREVIEW=denied|whenInUse|always|motionDenied|reducedAccuracy|notDetermined|restricted|paused`.
    /// Debug builds only: it changes what the page shows, never what is recorded.
    static func preview(named name: String?, from live: Self) -> Self? {
        guard let name else { return nil }
        var inputs = live
        inputs.errorMessage = nil
        inputs.isDemoMode = false
        inputs.isPreciseLocation = true
        inputs.isBackgroundListeningEnabled = true
        inputs.isRouteTrackingActive = false
        inputs.motion = .authorized
        inputs.authorization = .authorizedAlways
        switch name {
        case "denied": inputs.authorization = .denied
        case "whenInUse": inputs.authorization = .authorizedWhenInUse
        case "always": break
        case "motionDenied": inputs.motion = .denied
        case "reducedAccuracy": inputs.isPreciseLocation = false
        case "notDetermined": inputs.authorization = .notDetermined
        case "restricted": inputs.authorization = .restricted
        case "paused": inputs.isBackgroundListeningEnabled = false
        default: return nil
        }
        inputs.trackingStatusText = inputs.authorization == .authorizedAlways
            ? "Tracking in background"
            : live.trackingStatusText
        return inputs
    }
    #endif

    var motionIsOff: Bool {
        guard !isDemoMode else { return false }
        return motion == .denied || motion == .restricted
    }

    var status: Status {
        if let error = errorMessage {
            return Status(
                title: String(localized: "Tracking ran into a problem"),
                message: error,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }

        if isDemoMode {
            return Status(
                title: trackingStatusText,
                message: String(localized: "Showing demo days. Nothing new is recorded here."),
                systemImage: "iphone",
                tint: .secondary
            )
        }

        switch authorization {
        case .notDetermined:
            return Status(
                title: String(localized: "Location access needed"),
                message: String(localized: "Allow location access so Moves can record your days."),
                systemImage: "location.slash",
                tint: .orange,
                action: .allowLocation
            )
        case .denied:
            return Status(
                title: String(localized: "Location access is off"),
                message: String(localized: "Turn on location for Moves in Settings to record your days."),
                systemImage: "location.slash",
                tint: .orange,
                action: .openSettings
            )
        case .restricted:
            return Status(
                title: String(localized: "Location access is blocked"),
                message: String(localized: "This iPhone doesn’t allow Moves to use location."),
                systemImage: "lock.fill",
                tint: .secondary
            )
        case .authorizedWhenInUse:
            if !isBackgroundListeningEnabled {
                return pausedStatus
            }
            return Status(
                title: String(localized: "Recording only while Moves is open"),
                message: String(localized: "Choose Always in Settings so Moves can record in the background."),
                systemImage: "location.fill",
                tint: .orange,
                action: .openSettings
            )
        case .authorizedAlways:
            if !isBackgroundListeningEnabled, !isRouteTrackingActive {
                return pausedStatus
            }
            if !isPreciseLocation {
                return Status(
                    title: String(localized: "Precise Location is off"),
                    message: String(localized: "Turn it on to follow your walks and drives."),
                    systemImage: "location.circle",
                    tint: .orange,
                    action: .openSettings
                )
            }
            return Status(
                title: trackingStatusText,
                message: String(localized: "Moves records your places and trips, even when it’s closed."),
                systemImage: "location.fill",
                tint: MovesPalette.place
            )
        @unknown default:
            return Status(
                title: trackingStatusText,
                message: "",
                systemImage: "questionmark.circle",
                tint: .secondary
            )
        }
    }

    private var pausedStatus: Status {
        Status(
            title: String(localized: "Background recording is off"),
            message: String(localized: "Moves isn’t recording until you turn it back on below."),
            systemImage: "location.slash",
            tint: .secondary
        )
    }
}

extension TrackingSettingsPage {
    fileprivate typealias FixAction = TrackingStatusInputs.FixAction

    private var statusCard: some View {
        let status = status
        return SettingsCard(title: String(localized: "Status")) {
            statusLine(
                title: status.title,
                message: status.message,
                systemImage: status.systemImage,
                tint: status.tint
            )

            if let action = status.action {
                fixButton(action)
            }

            if motionIsOff {
                Divider()

                statusLine(
                    title: String(localized: "Motion & Fitness is off"),
                    message: String(localized: "Travel modes are less accurate without it."),
                    systemImage: "figure.walk.motion",
                    tint: .orange
                )

                if inputs.motion == .denied {
                    fixButton(.openSettings)
                }
            }
        }
    }

    private func statusLine(title: String, message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !message.isEmpty {
                    SettingsFootnote(message)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func fixButton(_ action: FixAction) -> some View {
        Button {
            switch action {
            case .allowLocation:
                captureManager.requestTrackingAuthorization()
            case .openSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        } label: {
            Text(action == .allowLocation ? String(localized: "Allow Location Access") : String(localized: "Open Settings"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    // MARK: Detail

    private func detailOption(_ level: CaptureDetailLevel) -> some View {
        let isSelected = captureManager.captureDetailLevel == level
        return Button {
            captureManager.setCaptureDetailLevel(level)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    SettingsFootnote(level.summary)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MovesPalette.routeTracking)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Background and route tracking

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { captureManager.isBackgroundLocationListeningEnabled },
            set: { captureManager.setBackgroundLocationListeningEnabled($0) }
        )
    }

    private var isRouteTrackingActive: Bool {
        guard let endsAt = captureManager.temporaryRouteTrackingEndsAt else { return false }
        return endsAt > .now
    }
}
