import SwiftUI

/// Journey finder moved here from the retired Statistics & Search sheet.
struct InsightsConnectionsView: View {
    private enum Endpoint: String, Identifiable {
        case origin
        case destination

        var id: String { rawValue }
    }

    let snapshot: MovesStatisticsSnapshot

    @State private var originKey: String?
    @State private var destinationKey: String?
    @State private var includesIndirectConnections = true
    @State private var includesReturnTrips = false
    @State private var endpointBeingSelected: Endpoint?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: String(localized: "Find a connection")) {
                    ConnectionEndpointButton(
                        title: String(localized: "From"),
                        value: locationTitle(for: originKey),
                        systemImage: "circle.fill"
                    ) {
                        endpointBeingSelected = .origin
                    }

                    ConnectionEndpointButton(
                        title: String(localized: "To"),
                        value: locationTitle(for: destinationKey),
                        systemImage: "mappin.circle.fill"
                    ) {
                        endpointBeingSelected = .destination
                    }

                    HStack {
                        Button {
                            swap(&originKey, &destinationKey)
                        } label: {
                            Label(String(localized: "Swap"), systemImage: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(originKey == nil && destinationKey == nil)

                        Spacer()
                    }

                    Divider()

                    Toggle(String(localized: "Include indirect connections"), isOn: $includesIndirectConnections)
                    Toggle(String(localized: "Include return trips"), isOn: $includesReturnTrips)

                    Text(String(localized: "Indirect connections can include up to eight legs and stops of up to 12 hours. Turn on return trips to calculate two-way commute statistics."))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                connectionResults
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(String(localized: "Connections"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $endpointBeingSelected) { endpoint in
            LocationSelectionView(
                title: endpoint == .origin
                    ? String(localized: "Choose Start")
                    : String(localized: "Choose Destination"),
                locations: snapshot.locations,
                selection: endpoint == .origin ? $originKey : $destinationKey
            )
        }
        .onAppear(perform: selectCommuteDefaultsIfAvailable)
    }

    @ViewBuilder
    private var connectionResults: some View {
        if let originKey, let destinationKey, originKey != destinationKey {
            let forward = snapshot.journeys(
                from: originKey,
                to: destinationKey,
                includingIndirect: includesIndirectConnections
            )
            let reverse = includesReturnTrips
                ? snapshot.journeys(
                    from: destinationKey,
                    to: originKey,
                    includingIndirect: includesIndirectConnections
                )
                : []
            let journeys = (forward + reverse).sorted { $0.startDate > $1.startDate }
            let statistics = MovesConnectionStatistics(journeys: journeys)

            if journeys.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Connections Found"),
                    systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                    description: Text(String(localized: "No matching recorded journey exists between these locations."))
                )
                .panelSurface()
            } else {
                SettingsCard(title: String(localized: "Journey Times")) {
                    Text("^[\(journeys.count) journey](inflect: true)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        InsightsMetric(
                            title: String(localized: "Minimum"),
                            value: MovesStatisticsFormatting.duration(statistics.minimumDuration)
                        )
                        InsightsMetric(
                            title: String(localized: "Average"),
                            value: MovesStatisticsFormatting.duration(statistics.averageDuration)
                        )
                        InsightsMetric(
                            title: String(localized: "Maximum"),
                            value: MovesStatisticsFormatting.duration(statistics.maximumDuration)
                        )
                    }
                }

                SettingsCard(title: String(localized: "Matching Journeys")) {
                    ForEach(journeys) { journey in
                        NavigationLink {
                            ConnectionJourneyDetailView(journey: journey)
                        } label: {
                            ConnectionJourneyRow(journey: journey)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            SettingsCard(title: String(localized: "Connection Search")) {
                Label(String(localized: "Choose two different locations"), systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(String(localized: "You will see when you traveled between them, plus minimum, average, and maximum journey times."))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func locationTitle(for key: String?) -> String? {
        guard let key else { return nil }
        return snapshot.locations.first(where: { $0.id == key })?.title
    }

    private func selectCommuteDefaultsIfAvailable() {
        guard originKey == nil, destinationKey == nil else { return }
        let homeNames = ["home", "zuhause"]
        let workNames = ["work", "office", "arbeit", "büro"]
        originKey = snapshot.locations.first { location in
            homeNames.contains { location.title.localizedCaseInsensitiveContains($0) }
        }?.id
        destinationKey = snapshot.locations.first { location in
            workNames.contains { location.title.localizedCaseInsensitiveContains($0) }
        }?.id
    }
}

struct InsightsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ConnectionEndpointButton: View {
    let title: String
    let value: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(MovesPalette.move)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value ?? String(localized: "Choose location"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

private struct ConnectionJourneyRow: View {
    let journey: MovesConnectionJourney

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: journey.isDirect ? "arrow.right.circle.fill" : "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(MovesPalette.move)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(journey.originTitle) → \(journey.destinationTitle)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(journey.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(MovesStatisticsFormatting.duration(journey.duration)) · \(MovesStatisticsFormatting.distance(journey.distanceMeters)) · \(journey.isDirect ? String(localized: "Direct") : String(localized: "\(journey.legs.count) legs"))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct LocationSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let locations: [MovesLocationSummary]
    @Binding var selection: String?
    @State private var searchText = ""

    private var filteredLocations: [MovesLocationSummary] {
        guard !searchText.isEmpty else { return locations }
        return locations.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredLocations) { location in
                Button {
                    selection = location.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(location.title)
                                .foregroundStyle(.primary)
                            Text("^[\(location.visitCount) visit](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == location.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .overlay {
                if filteredLocations.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "Search locations"))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct ConnectionJourneyDetailView: View {
    let journey: MovesConnectionJourney

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: String(localized: "Journey")) {
                    Text("\(journey.originTitle) → \(journey.destinationTitle)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(journey.startDate.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        InsightsMetric(
                            title: String(localized: "Time"),
                            value: MovesStatisticsFormatting.duration(journey.duration)
                        )
                        InsightsMetric(
                            title: String(localized: "Distance"),
                            value: MovesStatisticsFormatting.distance(journey.distanceMeters)
                        )
                        InsightsMetric(
                            title: String(localized: "Legs"),
                            value: journey.legs.count.formatted()
                        )
                    }
                }

                SettingsCard(title: String(localized: "Route Legs")) {
                    ForEach(journey.legs) { leg in
                        NavigationLink {
                            MoveMapDetailView(segment: leg)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: leg.transportMode.symbolName)
                                    .foregroundStyle(MovesPalette.transport(leg.transportMode))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(leg.startPlace?.displayTitle ?? String(localized: "Unknown")) → \(leg.endPlace?.displayTitle ?? String(localized: "Unknown"))")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text("\(MovesStatisticsFormatting.duration(leg.timelineDuration)) · \(MovesStatisticsFormatting.distance(leg.distanceMeters)) · \(leg.transportMode.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(String(localized: "Connection"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
