import MapKit
import SwiftData
import SwiftUI

/// Map, notes, photos in range, and a day-by-day storyline for one `NamedTrip`.
struct TripDetailView: View {
    let tripID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var rootController: MovesRootController
    @AppStorage(MapRouteShadingSettings.shadeRoutesBySpeedKey) private var shadeRoutesBySpeed = true

    @Query private var trips: [NamedTrip]
    @Query(sort: \DayTimeline.dayStart, order: .forward) private var dayTimelines: [DayTimeline]

    @State private var loader = MapWindowLoader()
    @State private var camera: MapCameraPosition = .automatic
    @State private var photos: [PhotoAttachment] = []
    @State private var daySections: [TripDaySection] = []
    @State private var isConfirmingDelete = false
    @State private var notesDraft = ""
    @State private var nameDraft = ""
    @State private var didLoadDrafts = false

    private var calendar: Calendar { .autoupdatingCurrent }

    init(tripID: UUID) {
        self.tripID = tripID
        let identifier = tripID
        _trips = Query(filter: #Predicate<NamedTrip> { $0.id == identifier })
    }

    private var trip: NamedTrip? { trips.first }

    var body: some View {
        Group {
            if let trip {
                content(trip)
            } else {
                ContentUnavailableView(
                    String(localized: "Trip unavailable"),
                    systemImage: "suitcase",
                    description: Text(String(localized: "This trip is no longer saved."))
                )
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
        .navigationTitle(trip?.name ?? String(localized: "Trip"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "Open in Map"), systemImage: "map") {
                        openInMap()
                    }
                    Button(String(localized: "Delete trip"), systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "Trip actions"))
            }
        }
        .confirmationDialog(
            String(localized: "Delete trip?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete trip"), role: .destructive) {
                deleteTrip()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Days, visits, and photos stay on your timeline."))
        }
        .task(id: tripID) {
            await reloadLens()
        }
        .onChange(of: loader.cameraFitKey) { _, _ in
            fitCamera()
        }
    }

    private func content(_ trip: NamedTrip) -> some View {
        List {
            Section {
                tripMap
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField(String(localized: "Name"), text: $nameDraft)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .onChange(of: nameDraft) { _, newValue in
                        persistName(newValue, on: trip)
                    }
                TextField(String(localized: "Notes"), text: $notesDraft, axis: .vertical)
                    .lineLimit(3...10)
                    .onChange(of: notesDraft) { _, newValue in
                        persistNotes(newValue, on: trip)
                    }
            } header: {
                Text(TripRangeStats.dateSpanTitle(for: trip.interval, calendar: calendar))
            }

            Section {
                TripPhotoStrip(photos: photos)
            } header: {
                Text(String(localized: "Photos"))
            }

            ForEach(daySections) { section in
                Section {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            openInTimeline(entry.startDate)
                        } label: {
                            StorylineRow(
                                entry: entry,
                                isFirst: index == 0,
                                isLast: index == section.entries.count - 1
                            )
                            .tint(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(section.dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            fillDraftsIfNeeded(from: trip)
        }
    }

    private var tripMap: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(loader.routes) { item in
                let route = item.rendered
                if route.shadowCoordinates.count > 1 {
                    MapPolyline(coordinates: route.shadowCoordinates)
                        .stroke(route.shadowTint, lineWidth: route.shadowLineWidth)
                }
                if route.coordinates.count > 1 {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(
                            route.strokeGradient(shadeBySpeed: shadeRoutesBySpeed, emphasis: 1),
                            style: RouteStrokeStyle.make(for: route)
                        )
                    if let overlayTint = route.recordedOverlayTint {
                        MapPolyline(coordinates: route.coordinates)
                            .stroke(
                                MovesPalette.opaqueRouteColor(overlayTint, opacity: 1),
                                style: RouteStrokeStyle.make(for: route, lineWidth: max(route.lineWidth - 2.25, 1.25))
                            )
                    }
                }
            }
            ForEach(loader.visits) { visit in
                Annotation(visit.title, coordinate: visit.coordinate, anchor: .center) {
                    MapLocationDot(tint: MovesPalette.place, isSelected: false)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityLabel(String(localized: "Trip map"))
    }

    private func fillDraftsIfNeeded(from trip: NamedTrip) {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true
        nameDraft = trip.name
        notesDraft = trip.notes
    }

    private func persistName(_ name: String, on trip: NamedTrip) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != trip.name else { return }
        trip.name = trimmed
        try? modelContext.save()
    }

    private func persistNotes(_ notes: String, on trip: NamedTrip) {
        guard notes != trip.notes else { return }
        trip.notes = notes
        try? modelContext.save()
    }

    @MainActor
    private func reloadLens() async {
        guard let trip else { return }
        fillDraftsIfNeeded(from: trip)
        let selection = MapRangeSelection.custom(
            start: trip.interval.start,
            end: trip.interval.end,
            calendar: calendar
        )
        await loader.load(
            selection: selection,
            modelContext: modelContext,
            cameraRegion: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ),
            calendar: calendar
        )
        photos = (try? TripRangeStats.photos(in: trip.interval, context: modelContext)) ?? []
        daySections = Self.makeDaySections(
            interval: trip.interval,
            dayTimelines: dayTimelines,
            calendar: calendar
        )
        fitCamera()
    }

    private func fitCamera() {
        let coordinates = loader.routes.flatMap(\.rendered.coordinates) + loader.visits.map(\.coordinate)
        guard !coordinates.isEmpty else { return }
        camera = .region(MapRegionFactory.region(for: coordinates))
    }

    private func openInMap() {
        guard let trip else { return }
        rootController.selectedTab = .map
        rootController.requestedMapInterval = trip.interval
        dismiss()
    }

    private func openInTimeline(_ date: Date) {
        if let url = MapDeepLink.timelineURL(at: date) {
            openURL(url)
        } else {
            rootController.selectedTab = .timeline
            rootController.requestedJumpDate = date
            rootController.requestedJumpMoment = date
        }
    }

    private func deleteTrip() {
        guard let trip else { return }
        modelContext.undoManager?.setActionName(String(localized: "Delete trip"))
        modelContext.delete(trip)
        try? modelContext.save()
        dismiss()
    }

    /// Groups overlapping visits and moves by local day for the accordion.
    static func makeDaySections(
        interval: DateInterval,
        dayTimelines: [DayTimeline],
        calendar: Calendar
    ) -> [TripDaySection] {
        let overlapping = dayTimelines.filter { day in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day.dayStart) ?? day.dayStart.addingTimeInterval(86_400)
            return day.dayStart < interval.end && dayEnd > interval.start
        }
        return overlapping.compactMap { day -> TripDaySection? in
            let visits = day.places.filter { visit in
                let end = visit.departureDate ?? visit.arrivalDate
                return visit.arrivalDate < interval.end && end >= interval.start
            }
            let moves = day.moves.filter { move in
                move.startDate < interval.end && move.endDate > interval.start
            }
            var entries: [TimelineEntry] = visits.map(TimelineEntry.place) + moves.map(TimelineEntry.move)
            entries.sort { $0.startDate < $1.startDate }
            guard !entries.isEmpty else { return nil }
            return TripDaySection(dayStart: day.dayStart, entries: entries)
        }
    }
}

/// One accordion day inside trip detail.
struct TripDaySection: Identifiable {
    let dayStart: Date
    let entries: [TimelineEntry]

    var id: TimeInterval { dayStart.timeIntervalSinceReferenceDate }
}

/// Horizontal strip of photos attached in the trip’s range.
///
/// Thumbnails from the Photos library belong to WS9; without assets this
/// still shows a count of `PhotoAttachment` rows so the strip is not a blank hole.
struct TripPhotoStrip: View {
    let photos: [PhotoAttachment]

    var body: some View {
        if photos.isEmpty {
            Text(String(localized: "No photos in this range"))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { _, photo in
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.frostedFill)
                            Image(systemName: photo.latitude == nil ? "photo" : "photo.badge.location")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 72, height: 72)
                        .accessibilityLabel(Text(photo.capturedAt, format: .dateTime.hour().minute()))
                    }
                }
            }
        }
    }
}
