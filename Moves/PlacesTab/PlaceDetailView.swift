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
    @Query private var allVisits: [VisitPlace]
    @State private var visibleVisitCount = 100

    @State private var camera: MapCameraPosition
    @State private var isRenaming = false
    @State private var isMerging = false
    @State private var isConfirmingDelete = false

    init(placeID: UUID) {
        self.placeID = placeID
        let identifier = placeID
        _knownPlaces = Query(filter: #Predicate<KnownPlace> { $0.id == identifier })
        _allVisits = Query(filter: #Predicate<VisitPlace> { $0.knownPlace?.id == identifier && $0.dayTimeline != nil }, sort: \.arrivalDate, order: .reverse)
        _camera = State(initialValue: .automatic)
    }

    private var place: KnownPlace? { knownPlaces.first }

    private var visits: [VisitPlace] {
        allVisits
    }

    /// The summary maps every stay at the place (thousands at home) and rebuilds the
    /// occupancy grid, so it is worked out again only when the place or its stays change,
    /// not on every render.
    @State private var summaryMemo = PlaceSummaryMemo()

    private var summary: PlacesPlaceSummary? {
        guard let place else { return nil }
        var hasher = Hasher()
        let record = PlacesKnownRecord(place)
        hasher.combine(record.name)
        hasher.combine(record.category)
        hasher.combine(record.confirmedVisitCount)
        hasher.combine(record.footprintRadius)
        hasher.combine(record.countryCode)
        hasher.combine(record.locality)
        hasher.combine(visits.count)
        for visit in visits {
            hasher.combine(visit.id)
            hasher.combine(visit.arrivalDate)
            hasher.combine(visit.departureDate)
        }
        return summaryMemo.value(for: hasher.finalize()) {
            PlacesIndexBuilder.summary(
                for: record,
                visits: visits.map(PlacesVisitRecord.init),
                now: .now,
                calendar: .autoupdatingCurrent
            )
        }
    }

    /// Whether there is another place to merge into; a count, not a fetch of every place.
    private var hasOtherPlaces: Bool {
        ((try? modelContext.fetchCount(FetchDescriptor<KnownPlace>())) ?? 0) > 1
    }

    /// Every other place, nearest first. Read when the merge sheet opens, never per render.
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
        // The name shows once, in the header under the map, where it wraps and renames on
        // tap. The bar title is only for when the place is gone.
        .navigationTitle(place == nil ? String(localized: "Place") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "Rename"), systemImage: "pencil") {
                        isRenaming = true
                    }
                    categoryMenu
                    Button(String(localized: "Merge into…"), systemImage: "arrow.triangle.merge") {
                        isMerging = true
                    }
                    .disabled(!hasOtherPlaces)
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
        .modifier(PlaceRenameAlert(isPresented: $isRenaming, currentName: place?.name ?? "") { rename(to: $0) })
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
                identity(summary: summary)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
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
                    ForEach(visits.prefix(visibleVisitCount)) { visit in
                        Button {
                            openVisit(visit)
                        } label: {
                            PlaceVisitRow(visit: visit)
                        }
                        .buttonStyle(.plain)
                    }
                    if visibleVisitCount < visits.count {
                        Button(String(localized: "Show more visits")) { visibleVisitCount += 100 }
                            .font(.system(.body, design: .rounded).weight(.medium))
                    }
                } header: {
                    Text(PlaceVisitRow.withZone(String(localized: "Visits"), visits: visits))
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
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(String(localized: "Map of \(summary.name)"))
    }

    /// Name and one-tap label, the two things a person fixes most.
    private func identity(summary: PlacesPlaceSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isRenaming = true
            } label: {
                HStack(spacing: 8) {
                    Text(summary.name.isEmpty ? String(localized: "Untitled place") : summary.name)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Rename \(summary.name)"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([KnownPlaceCategory.home, .work, .gym]) { category in
                        let selected = summary.category == category
                        PlaceChip(
                            title: category.title,
                            systemImage: category.symbolName,
                            isSelected: selected
                        ) {
                            setCategory(selected ? nil : category)
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func statsGrid(summary: PlacesPlaceSummary) -> some View {
        let zone = PlaceTimeZone.timeZone(at: summary.coordinate) ?? .autoupdatingCurrent
        let last = summary.lastVisitAt.map { PlaceVisitRow.dayText(for: $0, in: zone, omittingThisYear: true) } ?? "—"
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                PlacesMetric(title: String(localized: "Visits"), value: summary.visitCount.formatted())
                PlacesMetric(title: String(localized: "Total time"), value: MovesStatisticsFormatting.duration(summary.totalStay))
            }
            GridRow {
                PlacesMetric(title: String(localized: "Average stay"), value: MovesStatisticsFormatting.duration(summary.averageStay))
                PlacesMetric(title: String(localized: "Last visit"), value: last)
            }
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
        rootController.requestedJumpDate = PlaceVisitRow.timelineDay(of: visit)
    }

    /// The pill undoes exactly this step, even if something else wrote to the store since.
    private func toast(_ name: String, _ step: AppUndoStep?) {
        guard let step else { return }
        let manager = modelContext.undoManager
        undoToast?.show(actionName: name) {
            step.undo(removingFrom: manager)
        }
    }

    private func rename(to name: String) {
        guard let place else { return }
        do {
            let step = try PlacesLibrary.rename(place, to: name, in: modelContext)
            toast(String(localized: "Renamed"), step)
        } catch {}
    }

    private func setCategory(_ category: KnownPlaceCategory?) {
        guard let place else { return }
        do {
            let step = try PlacesLibrary.setCategory(place, to: category, in: modelContext)
            toast(category.map { String(localized: "Marked as \($0.title)") } ?? String(localized: "Label removed"), step)
        } catch {}
    }

    private func shrink() {
        guard let place else { return }
        do {
            let step = try PlacesLibrary.shrinkFootprint(place, in: modelContext)
            camera = .region(region(for: place))
            toast(String(localized: "Shrunk footprint"), step)
        } catch {}
    }

    private func merge(into target: KnownPlace) {
        guard let place else { return }
        do {
            let step = try PlacesLibrary.merge(place, into: target, in: modelContext)
            toast(String(localized: "Merged places"), step)
            dismiss()
        } catch {}
    }

    private func deletePlace() {
        guard let place else { return }
        do {
            let step = try PlacesLibrary.deletePlace(place, in: modelContext)
            toast(String(localized: "Deleted place"), step)
            dismiss()
        } catch {}
    }
}

/// Unassigned cluster: confirm form as the hero, visits below.
struct SuggestedPlaceDetailView: View {
    let cluster: PlacesSuggestedCluster
    var onConfirmed: (UUID) -> Void

    /// The one name on this screen: the title shows exactly what Confirm will save.
    @State private var name: String

    init(cluster: PlacesSuggestedCluster, onConfirmed: @escaping (UUID) -> Void) {
        self.cluster = cluster
        self.onConfirmed = onConfirmed
        _name = State(initialValue: PlaceConfirmForm.initialName(for: cluster))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    PlaceConfirmForm(
                        cluster: cluster,
                        name: $name,
                        onConfirmed: { place in onConfirmed(place.id) },
                        onNameFocusChange: { focused in
                            guard focused else { return }
                            withAnimation { proxy.scrollTo(PlaceConfirmFormAnchor.id, anchor: .bottom) }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .id(PlaceConfirmFormAnchor.id)
                }

                SuggestedVisitsSection(visitIDs: cluster.visitIDs)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .movesFloatingTabBarClearance()
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(PlaceDisplayNamer.meaningful(name) ?? String(localized: "New place"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Rename alert. It keeps the draft itself, so typing re-renders only the alert and
/// not the page with its stats over every visit.
private struct PlaceRenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    let currentName: String
    let onSave: (String) -> Void
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "Rename"), isPresented: $isPresented) {
                TextField(String(localized: "Name"), text: $draft)
                Button(String(localized: "Save")) { onSave(draft) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .onChange(of: isPresented) { _, presented in
                if presented { draft = currentName }
            }
    }
}

/// The suggested cluster's stays, newest first. Its own view, with inputs that typing a
/// name does not change, so a keystroke never re-reads or re-lists a thousand stays.
private struct SuggestedVisitsSection: View {
    @EnvironmentObject private var rootController: MovesRootController
    @Query private var visits: [VisitPlace]
    @State private var visibleVisitCount = 100

    init(visitIDs: [UUID]) {
        _visits = Query(
            filter: #Predicate<VisitPlace> { visitIDs.contains($0.id) && $0.dayTimeline != nil },
            sort: \VisitPlace.arrivalDate,
            order: .reverse
        )
    }

    var body: some View {
        if !visits.isEmpty {
            Section {
                ForEach(visits.prefix(visibleVisitCount)) { visit in
                    Button {
                        rootController.selectedTab = .timeline
                        rootController.requestedJumpDate = PlaceVisitRow.timelineDay(of: visit)
                    } label: {
                        PlaceVisitRow(visit: visit)
                    }
                    .buttonStyle(.plain)
                }
                if visibleVisitCount < visits.count {
                    Button(String(localized: "Show more visits")) { visibleVisitCount += 100 }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            } header: {
                Text(PlaceVisitRow.withZone(
                    visits.count == 1
                        ? String(localized: "1 visit")
                        : String(localized: "\(visits.count) visits"),
                    visits: visits
                ))
            }
        }
    }
}

/// A visit to a place, dated and timed on the clock where it happened.
struct PlaceVisitRow: View {
    let visit: VisitPlace

    private var zone: TimeZone { visit.placeTimeZone }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(MovesPalette.place)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detailLine)
                    .font(.system(.caption, design: .rounded).weight(.medium))
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
        Self.dayText(for: visit.arrivalDate, in: zone)
    }

    private var detailLine: String {
        Self.detailText(arrival: visit.arrivalDate, stay: visit.stayDuration(now: .now), in: zone)
    }

    /// "Today", "Yesterday", or the date `date` fell on in `zone`.
    static func dayText(
        for date: Date,
        in zone: TimeZone,
        omittingThisYear: Bool = false,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = .now
    ) -> String {
        // The visit's own date, as midnight on the phone's calendar, so Today and
        // Yesterday compare with the phone's today like the Timeline's days do.
        let day = PlaceClock.calendarDate(of: date, in: zone, on: calendar)
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let base: Date.FormatStyle = omittingThisYear && calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? .dateTime.month(.abbreviated).day()
            : Date.FormatStyle(date: .abbreviated, time: .omitted)
        return PlaceClock.format(day, base, in: calendar.timeZone)
    }

    /// "4:22 PM · 2 hr" on `zone`'s clock.
    static func detailText(arrival: Date, stay: TimeInterval, in zone: TimeZone) -> String {
        let time = PlaceClock.format(arrival, Date.FormatStyle(date: .omitted, time: .shortened), in: zone)
        return "\(time) · \(MovesStatisticsFormatting.duration(stay))"
    }

    /// `title`, plus the zone the times below are read in when it is not the phone's,
    /// as the Timeline's day header does ("Visits · PDT").
    static func withZone(_ title: String, visits: [VisitPlace]) -> String {
        guard let latest = visits.first,
              let zone = PlaceClock.foreignAbbreviation(of: latest.placeTimeZone, at: latest.arrivalDate)
        else { return title }
        return "\(title) · \(zone)"
    }

    /// The Timeline day this visit is filed on, as the date the Timeline pages by.
    static func timelineDay(of visit: VisitPlace) -> Date {
        visit.dayTimeline?.calendarDate() ?? PlaceClock.calendarDate(of: visit.arrivalDate, in: visit.placeTimeZone)
    }
}

private struct PlacesMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
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
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                        if let locality = place.locality, !locality.isEmpty {
                            Text(locality)
                                .font(.system(.caption, design: .rounded).weight(.medium))
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

/// Remembers the last summary and the fingerprint it was built from. A plain box held in
/// `@State`, so filling it while the body runs does not ask for another render.
final class PlaceSummaryMemo {
    private var key: Int?
    private var summary: PlacesPlaceSummary?

    func value(for key: Int, build: () -> PlacesPlaceSummary) -> PlacesPlaceSummary {
        if key == self.key, let summary { return summary }
        let built = build()
        self.key = key
        summary = built
        return built
    }
}
