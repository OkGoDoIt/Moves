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
            Image(systemName: summary.coverAssetLocalIdentifier == nil ? "suitcase.fill" : "photo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MovesPalette.place)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// Insights tab shell until yearly cards ship: placeholder copy plus a Trips entry.
struct InsightsTripsGatewayView: View {
    @EnvironmentObject private var controller: MovesRootController
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Your year at a glance."))
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                        Text(String(localized: "Distance, countries, streaks, and time-of-day patterns — compared with last year when there’s enough history."))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink(value: TripsNavigation.list) {
                        Label(String(localized: "Trips"), systemImage: "suitcase")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle(MovesTab.insights.title)
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: TripsNavigation.self) { route in
                switch route {
                case .list:
                    TripListView()
                case .detail(let tripID):
                    TripDetailView(tripID: tripID)
                }
            }
            .navigationDestination(for: UUID.self) { tripID in
                TripDetailView(tripID: tripID)
            }
        }
        .onAppear(perform: applyRequestedTrip)
        .onChange(of: controller.requestedTripID) { _, _ in
            applyRequestedTrip()
        }
    }

    private func applyRequestedTrip() {
        guard let tripID = controller.requestedTripID else { return }
        controller.requestedTripID = nil
        path.append(TripsNavigation.detail(tripID))
    }
}

/// In-tab destinations for the Insights gateway.
enum TripsNavigation: Hashable {
    case list
    case detail(UUID)
}
