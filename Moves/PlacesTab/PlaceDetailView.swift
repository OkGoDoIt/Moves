import MapKit
import SwiftData
import SwiftUI

/// Detail for a confirmed `KnownPlace`: map, stats, occupancy, visits, and edits.
struct PlaceDetailView: View {
    let placeID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var rootController: MovesRootController
    @Environment(\.undoToastPresenter) private var undoToast

    @Query private var knownPlaces: [KnownPlace]
    @Query(sort: \VisitPlace.arrivalDate, order: .reverse)
    private var allVisits: [VisitPlace]

    @State private var camera: MapCameraPosition
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isMerging = false
    @State private var isConfirmingDelete = false

    init(placeID: UUID) {
        self.placeID = placeID
        let identifier = placeID
        _knownPlaces = Query(filter: #Predicate<KnownPlace> { $0.id == identifier })
        _camera = State(initialValue: .automatic)
    }

    private var place: KnownPlace? { knownPlaces.first }

    private var visits: [VisitPlace] {
        allVisits.filter { $0.knownPlace?.id == placeID }
    }

    private var summary: PlacesPlaceSummary? {
        guard let place else { return nil }
        return PlacesIndexBuilder.summary(
            for: PlacesKnownRecord(place),
            visits: visits.map(PlacesVisitRecord.init),
            now: .now,
            calendar: .autoupdatingCurrent
        )
    }

    private var mergeCandidates: [KnownPlace] {
        guard let place else { return [] }
        let origin = CLLocation(latitude: place.centerLatitude, longitude: place.centerLongitude)
        return (try? modelContext.fetch(FetchDescriptor<KnownPlace>()))?
            .filter { $0.id != place.id }
            .sorted { lhs, rhs in
                let left = origin.distance(from: CLLocation(latitude: lhs.centerLatitude, longitude: lhs.centerLongitude))
                let right = origin.distance(from: CLLocation(latitude: rhs.centerLatitude, longitude: rhs.centerLongitude))
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } ?? []
    }

    var body: some View {
        Group {
            if let place, let summary {
                content(place: place, summary: summary)
            } else {
                ContentUnavailableView(
                    String(localized: "Place unavailable"),
                    systemImage: "mappin.slash",
                    description: Text(String(localized: "This place is no longer in your library."))
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
        .navigationTitle(place?.name ?? String(localized: "Place"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "Rename"), systemImage: "pencil") {
                        draftName = place?.name ?? ""
                        isRenaming = true
                    }
                    categoryMenu
                    Button(String(localized: "Merge into…"), systemImage: "arrow.triangle.merge") {
                        isMerging = true
                    }
                    .disabled(mergeCandidates.isEmpty)
                    Button(String(localized: "Shrink footprint"), systemImage: "minus.circle") {
                        shrink()
                    }
                    Divider()
                    Button(String(localized: "Delete place"), systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(place == nil)
            }
        }
        .alert(String(localized: "Rename"), isPresented: $isRenaming) {
            TextField(String(localized: "Name"), text: $draftName)
            Button(String(localized: "Save")) { rename() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Delete this place?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete place"), role: .destructive) { deletePlace() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Visits stay on your timeline. Only the learned place is removed."))
        }
        .sheet(isPresented: $isMerging) {
            MergePlaceSheet(candidates: mergeCandidates) { target in
                merge(into: target)
            }
        }
        .onAppear {
            if let place {
                camera = .region(region(for: place))
            }
        }
    }

    @ViewBuilder
    private var categoryMenu: some View {
        Menu(String(localized: "Set category"), systemImage: "tag") {
            Button(String(localized: "None")) { setCategory(nil) }
            ForEach(KnownPlaceCategory.allCases) { category in
                Button(category.title) { setCategory(category) }
            }
        }
    }

    private func content(place: KnownPlace, summary: PlacesPlaceSummary) -> some View {
        List {
            Section {
                footprintMap(place: place, summary: summary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                statsGrid(summary: summary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                    .listRowBackground(Color.clear)
            }

            Section {
                OccupancyChartView(grid: summary.occupancy)
            }

            if !visits.isEmpty {
                Section {
                    ForEach(visits) { visit in
                        Button {
                            openVisit(visit)
                        } label: {
                            PlaceVisitRow(visit: visit)
                        }
                    }
                } header: {
                    Text(String(localized: "Recent visits"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .movesFloatingTabBarClearance()
    }

    private func footprintMap(place: KnownPlace, summary: PlacesPlaceSummary) -> some View {
        Map(position: $camera) {
            MapCircle(center: place.coordinate, radius: place.footprintRadius)
                .foregroundStyle(MovesPalette.place.opacity(0.16))
                .stroke(MovesPalette.place.opacity(0.85), lineWidth: 2)
            Annotation(summary.name, coordinate: place.coordinate, anchor: .center) {
                PlacesCategoryGlyph(category: summary.category)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(String(localized: "\(Int(place.footprintRadius.rounded())) m footprint"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
        .accessibilityLabel(String(localized: "Map of \(summary.name)"))
    }

    private func statsGrid(summary: PlacesPlaceSummary) -> some View {
        let first = summary.firstVisitAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        let last = summary.lastVisitAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            PlacesMetric(title: String(localized: "Visits"), value: summary.visitCount.formatted())
            PlacesMetric(title: String(localized: "Total time"), value: MovesStatisticsFormatting.duration(summary.totalStay))
            PlacesMetric(title: String(localized: "Average stay"), value: MovesStatisticsFormatting.duration(summary.averageStay))
            PlacesMetric(title: String(localized: "First / last"), value: "\(first) · \(last)")
        }
    }

    private func region(for place: KnownPlace) -> MKCoordinateRegion {
        let meters = max(place.footprintRadius * 6, 180)
        return MKCoordinateRegion(
            center: place.coordinate,
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
    }

    private func openVisit(_ visit: VisitPlace) {
        rootController.selectedTab = .timeline
        rootController.requestedJumpDate = visit.arrivalDate
    }

    private func toast(_ name: String) {
        undoToast?.show(actionName: name) {
            modelContext.undoManager?.undo()
        }
    }

    private func rename() {
        guard let place else { return }
        do {
            try PlacesLibrary.rename(place, to: draftName, in: modelContext)
            toast(String(localized: "Renamed"))
        } catch {}
    }

    private func setCategory(_ category: KnownPlaceCategory?) {
        guard let place else { return }
        do {
            try PlacesLibrary.setCategory(place, to: category, in: modelContext)
            toast(String(localized: "Set category"))
        } catch {}
    }

    private func shrink() {
        guard let place else { return }
        do {
            try PlacesLibrary.shrinkFootprint(place, in: modelContext)
            camera = .region(region(for: place))
            toast(String(localized: "Shrunk footprint"))
        } catch {}
    }

    private func merge(into target: KnownPlace) {
        guard let place else { return }
        do {
            try PlacesLibrary.merge(place, into: target, in: modelContext)
            toast(String(localized: "Merged places"))
            dismiss()
        } catch {}
    }

    private func deletePlace() {
        guard let place else { return }
        do {
            try PlacesLibrary.deletePlace(place, in: modelContext)
            toast(String(localized: "Deleted place"))
            dismiss()
        } catch {}
    }
}

/// Unassigned cluster: confirm form as the hero, visits below.
struct SuggestedPlaceDetailView: View {
    let cluster: PlacesSuggestedCluster
    var onConfirmed: (UUID) -> Void

    @EnvironmentObject private var rootController: MovesRootController

    @Query(sort: \VisitPlace.arrivalDate, order: .reverse)
    private var allVisits: [VisitPlace]

    private var visits: [VisitPlace] {
        let wanted = Set(cluster.visitIDs)
        return allVisits.filter { wanted.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                PlaceConfirmForm(cluster: cluster) { place in
                    onConfirmed(place.id)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            } footer: {
                Text(String(localized: "Moves will use this name the next time you stop here."))
            }

            if !visits.isEmpty {
                Section(String(localized: "Visits")) {
                    ForEach(visits) { visit in
                        Button {
                            rootController.selectedTab = .timeline
                            rootController.requestedJumpDate = visit.arrivalDate
                        } label: {
                            PlaceVisitRow(visit: visit)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .movesFloatingTabBarClearance()
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(cluster.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaceVisitRow: View {
    let visit: VisitPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(MovesPalette.place)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(detailLine)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dayTitle), \(detailLine)")
    }

    /// Relative day or a date without the time, so the timestamp is not repeated.
    private var dayTitle: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(visit.arrivalDate) {
            return String(localized: "Today")
        }
        if calendar.isDateInYesterday(visit.arrivalDate) {
            return String(localized: "Yesterday")
        }
        return visit.arrivalDate.formatted(date: .abbreviated, time: .omitted)
    }

    private var detailLine: String {
        let time = visit.arrivalDate.formatted(date: .omitted, time: .shortened)
        let duration = MovesStatisticsFormatting.duration(visit.stayDuration(now: .now))
        return "\(time) · \(duration)"
    }
}

private struct PlacesMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MergePlaceSheet: View {
    let candidates: [KnownPlace]
    var onSelect: (KnownPlace) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates, id: \.id) { place in
                Button {
                    onSelect(place)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        if let locality = place.locality, !locality.isEmpty {
                            Text(locality)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Merge into"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
