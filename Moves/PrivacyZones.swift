import CoreImage
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// UserDefaults keys and defaults for Home / Work privacy circles.
enum PrivacyZoneSettings {
    static let isEnabledKey = "privacy.zones.enabled"
    static let hidesRawFixesInExportsKey = "privacy.zones.hideRawFixesInExports"

    /// Default circle around a Home or Work place, in meters.
    static let defaultRadiusMeters: CLLocationDistance = 200

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    /// When privacy zones are on, exports omit raw GPS samples inside a zone
    /// unless the user turns this off. Share cards still blur either way.
    static var hidesRawFixesInExports: Bool {
        if UserDefaults.standard.object(forKey: hidesRawFixesInExportsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: hidesRawFixesInExportsKey)
    }
}

/// A circle around a confirmed Home or Work place.
struct PrivacyZone: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var category: KnownPlaceCategory
    var latitude: Double
    var longitude: Double
    var radiusMeters: CLLocationDistance

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether `coordinate` falls inside this circle, using great-circle distance.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let there = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return here.distance(from: there) <= radiusMeters
    }
}

/// Builds privacy circles from learned places. Only Home and Work count.
enum PrivacyZoneResolver {
    /// Circles to draw on share cards when the feature is on.
    static func shareZones(
        from places: [KnownPlace],
        enabled: Bool = PrivacyZoneSettings.isEnabled,
        radiusMeters: CLLocationDistance = PrivacyZoneSettings.defaultRadiusMeters
    ) -> [PrivacyZone] {
        guard enabled else { return [] }
        return zones(from: places, radiusMeters: radiusMeters)
    }

    /// Circles used to strip raw GPS samples from exports.
    static func exportZones(
        from places: [KnownPlace],
        enabled: Bool = PrivacyZoneSettings.isEnabled,
        hidesRawFixes: Bool = PrivacyZoneSettings.hidesRawFixesInExports,
        radiusMeters: CLLocationDistance = PrivacyZoneSettings.defaultRadiusMeters
    ) -> [PrivacyZone] {
        guard enabled, hidesRawFixes else { return [] }
        return zones(from: places, radiusMeters: radiusMeters)
    }

    /// Home and Work places as 200 m circles. Other categories are ignored.
    static func zones(
        from places: [KnownPlace],
        radiusMeters: CLLocationDistance = PrivacyZoneSettings.defaultRadiusMeters
    ) -> [PrivacyZone] {
        places.compactMap { place in
            guard let category = KnownPlaceCategory(stored: place.category),
                  category == .home || category == .work
            else { return nil }
            return PrivacyZone(
                id: place.id,
                name: place.name,
                category: category,
                latitude: place.centerLatitude,
                longitude: place.centerLongitude,
                radiusMeters: radiusMeters
            )
        }
    }

    static func containsRawFix(
        latitude: Double,
        longitude: Double,
        zones: [PrivacyZone]
    ) -> Bool {
        guard !zones.isEmpty else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return zones.contains { $0.contains(coordinate) }
    }

    static func loadPlaces(from context: ModelContext) -> [KnownPlace] {
        (try? context.fetch(FetchDescriptor<KnownPlace>())) ?? []
    }
}

/// Blurs Home / Work circles on a share-card map snapshot.
enum PrivacyZoneShareBlur {
    /// Returns `image` with a Gaussian blur clipped to each zone.
    static func apply(
        to image: UIImage,
        zones: [PrivacyZone],
        snapshot: MKMapSnapshotter.Snapshot
    ) -> UIImage {
        guard !zones.isEmpty else { return image }
        guard let blurred = blurredCopy(of: image) else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let context = ctx.cgContext
            for zone in zones {
                let center = snapshot.point(for: zone.coordinate)
                let radius = max(screenRadius(for: zone, snapshot: snapshot), 22)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()
                blurred.draw(in: CGRect(origin: .zero, size: image.size))
                context.restoreGState()

                context.setStrokeColor(UIColor.white.withAlphaComponent(0.42).cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: rect)
            }
        }
    }

    private static func blurredCopy(of image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let blurred = ciImage
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 26)
            .cropped(to: ciImage.extent)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(blurred, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    /// Converts the zone’s metre radius into snapshot points using a 1 m north offset.
    private static func screenRadius(
        for zone: PrivacyZone,
        snapshot: MKMapSnapshotter.Snapshot
    ) -> CGFloat {
        let center = snapshot.point(for: zone.coordinate)
        let metersPerDegree = 111_320.0
        let north = CLLocationCoordinate2D(
            latitude: zone.coordinate.latitude + (zone.radiusMeters / metersPerDegree),
            longitude: zone.coordinate.longitude
        )
        let northPoint = snapshot.point(for: north)
        return hypot(northPoint.x - center.x, northPoint.y - center.y)
    }
}

/// Settings card: privacy circles stay off until Home or Work exists, or the user confirms one.
struct PrivacyZonesSettingsCard: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownPlace.name) private var knownPlaces: [KnownPlace]
    @AppStorage(PrivacyZoneSettings.isEnabledKey) private var isEnabled = false
    @AppStorage(PrivacyZoneSettings.hidesRawFixesInExportsKey) private var hidesRawFixesInExports = true
    @State private var isShowingHomeWorkPicker = false

    private var homeAndWork: [KnownPlace] {
        knownPlaces.filter {
            let category = KnownPlaceCategory(stored: $0.category)
            return category == .home || category == .work
        }
    }

    var body: some View {
        SettingsCard(title: String(localized: "Privacy")) {
            Toggle(String(localized: "Hide Home and Work"), isOn: enabledBinding)

            if isEnabled {
                Toggle(
                    String(localized: "Leave out exact GPS points near Home and Work when you export"),
                    isOn: $hidesRawFixesInExports
                )
            }

            Text(footer)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $isShowingHomeWorkPicker) {
            PrivacyHomeWorkPickerSheet(places: knownPlaces) { didConfirm in
                isShowingHomeWorkPicker = false
                if didConfirm {
                    isEnabled = true
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue {
                    if homeAndWork.isEmpty {
                        isShowingHomeWorkPicker = true
                    } else {
                        isEnabled = true
                    }
                } else {
                    isEnabled = false
                }
            }
        )
    }

    private var footer: String {
        if isEnabled {
            if homeAndWork.isEmpty {
                return String(localized: "Turned on, but no Home or Work yet. Share cards stay as they are until you set one in Places.")
            }
            let names = homeAndWork.map { $0.name.isEmpty ? $0.category?.capitalized ?? "" : $0.name }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return String(localized: "A 200 m circle around \(names) is blurred on share cards.")
        }
        return String(localized: "Keeps the streets around Home and Work off share cards and optional exports. Off until you set Home or Work.")
    }
}

/// Lets the user mark an existing place as Home or Work before privacy turns on.
private struct PrivacyHomeWorkPickerSheet: View {
    let places: [KnownPlace]
    let onFinish: (Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "Privacy uses a 200 m circle around Home and Work. Choose a place, or cancel to leave this off."))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                if places.isEmpty {
                    Section {
                        Text(String(localized: "Confirm a place in the Places tab first, then come back."))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(String(localized: "Your places")) {
                        ForEach(places, id: \.id) { place in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(place.name.isEmpty ? String(localized: "Untitled place") : place.name)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                HStack(spacing: 8) {
                                    Button(String(localized: "Home")) {
                                        confirm(place, category: .home)
                                    }
                                    .buttonStyle(.bordered)
                                    Button(String(localized: "Work")) {
                                        confirm(place, category: .work)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Set Home or Work"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        onFinish(false)
                        dismiss()
                    }
                }
            }
        }
    }

    private func confirm(_ place: KnownPlace, category: KnownPlaceCategory) {
        do {
            try PlacesLibrary.setCategory(place, to: category, in: modelContext)
            onFinish(true)
            dismiss()
        } catch {
            onFinish(false)
            dismiss()
        }
    }
}
