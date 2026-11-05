import SwiftData
import SwiftUI

/// Saved trips, newest start first. Reachable from Insights and the Map range menu.
struct TripListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NamedTrip.startDate, order: .reverse)
    private var trips: [NamedTrip]

    var body: some View {
        Group {
            if trips.isEmpty {
                emptyState
            } else {
                List(trips, id: \.id) { trip in
                    NavigationLink(value: trip.id) {
                        TripListRow(trip: trip)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(String(localized: "Delete"), role: .destructive) {
                            delete(trip)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .movesFloatingTabBarClearance()
            }
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(String(localized: "Trips"))
        .navigationBarTitleDisplayMode(.large)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No trips yet"), systemImage: "suitcase")
        } description: {
            Text(String(localized: "On the Map, choose a range and save it as a trip."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func delete(_ trip: NamedTrip) {
        modelContext.undoManager?.setActionName(String(localized: "Delete trip"))
        modelContext.delete(trip)
        try? modelContext.save()
    }
}

/// Name, date span, distance, countries, and an optional cover glyph.
private struct TripListRow: View {
    let trip: NamedTrip
    @Environment(\.modelContext) private var modelContext
    @State private var summary = TripListSummary.empty
    @State private var didLoadSummary = false

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(TripRangeStats.dateSpanTitle(for: trip.interval))
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metricsLine)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task(id: trip.id) {
            // Each summary reads the store on the main thread, so a row scrolling back doesn't redo it.
            guard !didLoadSummary else { return }
            didLoadSummary = true
            summary = TripRangeStats.summary(for: trip, in: modelContext)
        }
    }

    private var metricsLine: String {
        var parts: [String] = []
        if summary.distanceMeters > 0 {
            parts.append(
                Measurement(value: summary.distanceMeters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
        }
        if !summary.countryCodes.isEmpty {
            parts.append(summary.countryCodes.map(PlacesGeography.flagEmoji(forCountryCode:)).joined())
        }
        if summary.photoCount > 0 {
            parts.append("\(summary.photoCount)")
        }
        return parts.isEmpty ? String(localized: "No recorded activity") : parts.joined(separator: " · ")
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MovesPalette.place.opacity(0.14))
            if let identifier = summary.coverAssetLocalIdentifier {
                PhotoAssetThumbnail(identifier: identifier, cornerRadius: 10)
            } else {
                Image(systemName: "suitcase.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MovesPalette.place)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}
