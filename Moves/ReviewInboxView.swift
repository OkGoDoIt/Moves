import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// A single row in the Review inbox, computed on demand from stored flags.
struct ReviewInboxItem: Identifiable {
    enum Kind {
        case visit(VisitPlace)
        case move(MoveSegment)
    }

    enum Section: String, CaseIterable, Identifiable {
        case places
        case stops
        case trips

        var id: String { rawValue }

        var title: String {
            switch self {
            case .places: return String(localized: "Places")
            case .stops: return String(localized: "Stops")
            case .trips: return String(localized: "Trips")
            }
        }

        /// "Dismiss 12 trips?" — the noun the confirmation names.
        func dismissAllTitle(count: Int) -> String {
            switch self {
            case .places: return String(localized: "Dismiss \(count) places?")
            case .stops: return String(localized: "Dismiss \(count) stops?")
            case .trips: return String(localized: "Dismiss \(count) trips?")
            }
        }
    }

    var id: String
    var kind: Kind
    var section: Section
    var title: String
    /// "Sat, Nov 21 · 4:22 PM · 26 min"
    var when: String
    var question: String
    var date: Date
    var thumbnail: ReviewMapThumbnail.Content

    var itemID: UUID {
        switch kind {
        case .visit(let visit): return visit.id
        case .move(let move): return move.id
        }
    }
}

/// Builds inbox rows from visits and moves. Never a separate queue, and the only count
/// of what needs a look: anything that shows a number uses `items(...).count`.
enum ReviewInboxBuilder {
    static func items(
        visits: [VisitPlace],
        moves: [MoveSegment],
        now: Date = .now
    ) -> [ReviewInboxItem] {
        var items: [ReviewInboxItem] = []
        var seen = Set<UUID>()

        for visit in visits where seen.insert(visit.id).inserted {
            switch TimelineReviewHeuristics.question(for: visit, now: now) {
            case .whichPlace:
                items.append(item(for: visit, section: .places, title: placeTitle(visit),
                                  question: String(localized: "Is this the right place?")))
            case .notAStop:
                items.append(item(for: visit, section: .stops, title: placeTitle(visit),
                                  question: String(localized: "A stop, or a pause on the way?")))
            case .mode, nil:
                break
            }
        }

        for move in moves where seen.insert(move.id).inserted {
            guard TimelineReviewHeuristics.question(for: move, now: now) == .mode else { continue }
            items.append(
                ReviewInboxItem(
                    id: "mode-\(move.id.uuidString)",
                    kind: .move(move),
                    section: .trips,
                    title: tripTitle(move),
                    when: whenText(start: move.timelineStartDate, duration: move.timelineDuration),
                    question: String(localized: "How did you travel?"),
                    date: move.startDate,
                    thumbnail: .path(
                        pathCoordinates(for: move),
                        tint: MovesPalette.transport(move.transportMode)
                    )
                )
            )
        }

        return items.sorted { $0.date > $1.date }
    }

    /// Two likely modes for a trip, the current guess first when it has one.
    static func suggestedModes(for move: MoveSegment) -> [TransportMode] {
        let duration = move.endDate.timeIntervalSince(move.startDate)
        let speed = duration > 0 ? max(move.distanceMeters, 0) / duration : 0
        let bySpeed: [TransportMode]
        switch speed {
        case ..<2.5: bySpeed = [.walking, .cycling]
        case ..<7: bySpeed = [.cycling, .automotive]
        case ..<70: bySpeed = [.automotive, .train]
        default: bySpeed = [.plane, .automotive]
        }
        let current = move.transportMode
        guard current != .unknown, current != .stationary else { return bySpeed }
        return Array(([current] + bySpeed.filter { $0 != current }).prefix(2))
    }

    private static func item(
        for visit: VisitPlace,
        section: ReviewInboxItem.Section,
        title: String,
        question: String
    ) -> ReviewInboxItem {
        ReviewInboxItem(
            id: "\(section.rawValue)-\(visit.id.uuidString)",
            kind: .visit(visit),
            section: section,
            title: title,
            when: whenText(start: visit.arrivalDate, duration: TimelineReviewHeuristics.stayDuration(of: visit)),
            question: question,
            date: visit.arrivalDate,
            thumbnail: .spot(visit.coordinate, path: pathCoordinates(around: visit))
        )
    }

    static func whenText(start: Date, duration: TimeInterval?) -> String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time = start.formatted(date: .omitted, time: .shortened)
        guard let duration else { return "\(day) · \(time)" }
        return "\(day) · \(time) · \(durationText(duration))"
    }

    /// Same compact form as the timeline's "Stayed 42m": `<1m`, `26m`, `1h 5m`.
    static func durationText(_ duration: TimeInterval) -> String {
        DurationFormatter.compactText(for: duration)
    }

    private static func placeTitle(_ visit: VisitPlace) -> String {
        if visit.assignmentSource == .autoAmbiguous,
           let known = PlaceDisplayNamer.meaningful(visit.knownPlace?.name) {
            return known
        }
        return visit.placesDisplayName
    }

    private static func tripTitle(_ move: MoveSegment) -> String {
        let start = move.startPlace.map(placeTitle)
        let end = move.endPlace.map(placeTitle)
        switch (start, end) {
        case let (start?, end?) where start != end:
            return "\(start) → \(end)"
        case let (start?, _):
            return start
        case let (nil, end?):
            return end
        default:
            return move.transportMode.title
        }
    }

    /// The drawn path, or the raw fixes when no path has been drawn yet.
    private static func pathCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        let displayed = TimelineLocator.displayedCoordinates(for: move)
        if displayed.count > 2 { return displayed }
        let fixes = move.samples.sorted { $0.timestamp < $1.timestamp }.map(\.coordinate)
        return fixes.count >= 2 ? fixes : displayed
    }

    /// The way in and out of a stay, so a pause on a straight path reads as one.
    private static func pathCoordinates(around visit: VisitPlace) -> [CLLocationCoordinate2D] {
        let incoming = visit.incomingMoves.max { $0.endDate < $1.endDate }
        let outgoing = visit.outgoingMoves.min { $0.startDate < $1.startDate }
        let path = (incoming.map(pathCoordinates(for:)) ?? []) + [visit.coordinate]
            + (outgoing.map(pathCoordinates(for:)) ?? [])
        let center = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        return path.filter {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: center) <= 1_200
        }
    }
}

/// Pending rows the inbox reads. Only open questions, so old history stays out of memory.
private enum ReviewInboxQuery {
    static var visits: FetchDescriptor<VisitPlace> {
        let pending = ReviewState.pending.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.reviewStateRaw == pending },
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
    }

    static var moves: FetchDescriptor<MoveSegment> {
        let pending = ReviewState.pending.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.reviewStateRaw == pending },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
    }
}

// MARK: - Entry point

/// Compact capsule that shows how many items need a look and opens the Review inbox.
/// Hidden when there is nothing to ask.
struct ReviewEntryButton: View {
    @EnvironmentObject private var rootController: MovesRootController
    @Query(ReviewInboxQuery.visits) private var visits: [VisitPlace]
    @Query(ReviewInboxQuery.moves) private var moves: [MoveSegment]

    private var count: Int {
        ReviewInboxBuilder.items(visits: visits, moves: moves).count
    }

    var body: some View {
        // Waits for the launch pass, so the first number shown is the one that stays.
        let count = rootController.hasSettledReviewQuestions ? count : 0
        if count > 0 {
            Button {
                rootController.isShowingReviewInbox = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(MovesPalette.place)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    // Beside Today and a Route Tracking countdown there is only room for the number.
                    ViewThatFits(in: .horizontal) {
                        Text(String(localized: "\(count) to review"))
                        Text(count, format: .number)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(.thinMaterial, in: Capsule())
                .overlay { Capsule().stroke(MovesPalette.border, lineWidth: 0.5) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Review, \(count) items"))
            .accessibilityHint(String(localized: "Opens stays and trips to check"))
        }
    }
}

// MARK: - Inbox

/// Inbox of recent stays and trips worth a look, opened from `ReviewEntryButton` or `moves://review`.
struct ReviewInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timelineEditController) private var editController
    @Environment(\.undoToastPresenter) private var undoToast
    @EnvironmentObject private var rootController: MovesRootController

    @Query(ReviewInboxQuery.visits) private var visits: [VisitPlace]
    @Query(ReviewInboxQuery.moves) private var moves: [MoveSegment]

    @State private var confirmingSection: ReviewInboxItem.Section?

    /// Above this many rows, "Dismiss all" asks first.
    private static let dismissAllConfirmationThreshold = 5

    var body: some View {
        let items = ReviewInboxBuilder.items(visits: visits, moves: moves)
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "You’re all caught up"),
                        systemImage: "checkmark.circle",
                        description: Text(String(localized: "Stays and trips worth a second look show up here."))
                    )
                } else {
                    List {
                        ForEach(ReviewInboxItem.Section.allCases) { section in
                            let rows = items.filter { $0.section == section }
                            if !rows.isEmpty {
                                Section {
                                    ForEach(rows) { item in
                                        row(item)
                                    }
                                } header: {
                                    sectionHeader(section, rows: rows)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(localized: "Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                confirmingSection.map { section in
                    section.dismissAllTitle(count: items.filter { $0.section == section }.count)
                } ?? "",
                isPresented: Binding(
                    get: { confirmingSection != nil },
                    set: { if !$0 { confirmingSection = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let section = confirmingSection {
                    Button(String(localized: "Dismiss All"), role: .destructive) {
                        dismissAll(items.filter { $0.section == section })
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "You can undo this right after."))
            }
        }
        .modifier(OptionalUndoToast(presenter: undoToast))
    }

    private func sectionHeader(_ section: ReviewInboxItem.Section, rows: [ReviewInboxItem]) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            Button(String(localized: "Dismiss All")) {
                if rows.count > Self.dismissAllConfirmationThreshold {
                    confirmingSection = section
                } else {
                    dismissAll(rows)
                }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
            .buttonStyle(.borderless)
        }
    }

    private func row(_ item: ReviewInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                open(item)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    ReviewMapThumbnail(content: item.thumbnail, key: item.id)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(item.when)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(item.question)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Shows it on the timeline"))

            actions(for: item)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(String(localized: "Dismiss")) {
                dismissOne(item)
            }
            .tint(.gray)
        }
        .contextMenu {
            Button(String(localized: "Show on Timeline"), systemImage: "calendar") { open(item) }
            Button(String(localized: "Dismiss"), systemImage: "xmark") { dismissOne(item) }
        }
    }

    @ViewBuilder
    private func actions(for item: ReviewInboxItem) -> some View {
        if let editor = editController {
            switch item.kind {
            case .visit(let visit):
                HStack(spacing: 8) {
                    if item.section == .places {
                        Button(String(localized: "Yes")) { editor.confirmPlace(visit) }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Pick Another")) { editor.requestPickNearby(visit) }
                            .buttonStyle(.bordered)
                    } else {
                        Button(String(localized: "Not a Stop")) { editor.markNotAStop(visit) }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Keep Stop")) { editor.keepStop(visit) }
                            .buttonStyle(.bordered)
                    }
                }
            case .move(let move):
                let suggestions = ReviewInboxBuilder.suggestedModes(for: move)
                HStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, mode in
                        let button = Button {
                            editor.setTransportMode(mode, for: move)
                        } label: {
                            Label(mode.chipTitle, systemImage: mode.symbolName)
                        }
                        if index == 0 {
                            button.buttonStyle(.borderedProminent)
                        } else {
                            button.buttonStyle(.bordered)
                        }
                    }
                    Menu {
                        ForEach(TransportMode.correctionChoices.filter { !suggestions.contains($0) }, id: \.self) { mode in
                            Button(mode.title, systemImage: mode.symbolName) {
                                editor.setTransportMode(mode, for: move)
                            }
                        }
                    } label: {
                        Text(String(localized: "Other"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func open(_ item: ReviewInboxItem) {
        dismiss()
        rootController.selectedTab = .timeline
        // The middle of the stay or trip, so the timeline lands on its day and highlights
        // that row rather than a neighbor that ends or starts at the same minute.
        let moment: Date
        switch item.kind {
        case .visit(let visit):
            let end = visit.departureDate ?? visit.arrivalDate
            moment = visit.arrivalDate.addingTimeInterval(end.timeIntervalSince(visit.arrivalDate) / 2)
        case .move(let move):
            moment = move.startDate.addingTimeInterval(move.endDate.timeIntervalSince(move.startDate) / 2)
        }
        rootController.requestedJumpDate = moment
        rootController.requestedJumpMoment = moment
    }

    private func dismissOne(_ item: ReviewInboxItem) {
        dismissAll([item])
    }

    private func dismissAll(_ rows: [ReviewInboxItem]) {
        var visitIDs: [UUID] = []
        var moveIDs: [UUID] = []
        for row in rows {
            switch row.kind {
            case .visit: visitIDs.append(row.itemID)
            case .move: moveIDs.append(row.itemID)
            }
        }
        editController?.dismissReviews(visitIDs: visitIDs, moveIDs: moveIDs)
    }
}

/// The inbox is a sheet over the root's Undo pill, so it shows the same pill itself.
private struct OptionalUndoToast: ViewModifier {
    var presenter: UndoToastPresenter?

    func body(content: Content) -> some View {
        if let presenter {
            content.undoToast(presenter)
        } else {
            content
        }
    }
}

// MARK: - Map thumbnail

/// Small static map of a stay or a trip's path.
struct ReviewMapThumbnail: View {
    enum Content {
        case spot(CLLocationCoordinate2D, path: [CLLocationCoordinate2D])
        case path([CLLocationCoordinate2D], tint: Color)
    }

    let content: Content
    let key: String
    var side: CGFloat = 64

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(MovesPalette.frostedFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MovesPalette.border, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
            .task(id: "\(key)|\(colorScheme == .dark)") {
                image = await ReviewMapThumbnailRenderer.image(
                    for: content,
                    key: key,
                    size: CGSize(width: side, height: side),
                    scale: displayScale,
                    dark: colorScheme == .dark
                )
            }
    }
}

@MainActor
private enum ReviewMapThumbnailRenderer {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    static func image(
        for content: ReviewMapThumbnail.Content,
        key: String,
        size: CGSize,
        scale: CGFloat,
        dark: Bool
    ) async -> UIImage? {
        let cacheKey = "\(key)|\(dark)|\(size.width)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let path: [CLLocationCoordinate2D]
        let focus: CLLocationCoordinate2D?
        let color: UIColor
        switch content {
        case let .spot(coordinate, around):
            path = around
            focus = coordinate
            color = UIColor(MovesPalette.move)
        case let .path(coordinates, tint):
            path = coordinates
            focus = nil
            color = UIColor(tint)
        }
        let regionPoints = path + [focus].compactMap { $0 }
        guard !regionPoints.isEmpty else { return nil }

        let options = MKMapSnapshotter.Options()
        var region = MapRegionFactory.region(for: regionPoints)
        if focus != nil {
            // A stay alone would zoom to the floor; keep a few streets around it.
            region.span.latitudeDelta = max(region.span.latitudeDelta, 0.006)
            region.span.longitudeDelta = max(region.span.longitudeDelta, 0.006)
        }
        options.region = MapRegionFactory.snapshotSafe(region)
        options.size = size
        options.scale = scale
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        let rendered = UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            RouteSnapshotStroke.strokePath(
                coordinates: path,
                in: snapshot,
                color: color,
                lineWidth: 3,
                dash: []
            )
            let marker: CLLocationCoordinate2D? = focus ?? path.last
            if let marker {
                let point = snapshot.point(for: marker)
                let radius: CGFloat = focus != nil ? 6 : 4
                let dot = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                UIColor(focus != nil ? MovesPalette.place : MovesPalette.start).setFill()
                dot.fill()
                UIColor.white.setStroke()
                dot.lineWidth = 2
                dot.stroke()
            }
        }
        cache.setObject(rendered, forKey: cacheKey)
        return rendered
    }
}

/// Change the inferred transport mode for a move.
struct TransportModePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let move: MoveSegment
    var editController: TimelineEditController

    var body: some View {
        NavigationStack {
            List {
                ForEach(TransportMode.correctionChoices, id: \.self) { mode in
                    Button {
                        editController.setTransportMode(mode, for: move)
                        dismiss()
                    } label: {
                        Label(mode.title, systemImage: mode.symbolName)
                    }
                }
            }
            .navigationTitle(String(localized: "Change mode"))
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
