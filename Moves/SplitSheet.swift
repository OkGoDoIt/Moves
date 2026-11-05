import MapKit
import SwiftData
import SwiftUI

/// Time slider over a visit or move, with a map preview of the split point.
struct SplitSheet: View {
    enum Target {
        case visit(VisitPlace)
        case move(MoveSegment)
    }

    @Environment(\.dismiss) private var dismiss

    let target: Target
    var editController: TimelineEditController

    @State private var progress: Double = 0.5
    @State private var camera: MapCameraPosition

    init(target: Target, editController: TimelineEditController) {
        self.target = target
        self.editController = editController
        let coordinate = Self.coordinate(for: target, progress: 0.5)
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Map(position: $camera) {
                    if case .move(let move) = target {
                        let coordinates = TimelineLocator.displayedCoordinates(for: move)
                        if coordinates.count > 1 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(MovesPalette.transport(move.transportMode), lineWidth: 4)
                        }
                    }
                    Annotation(String(localized: "Split"), coordinate: currentCoordinate, anchor: .center) {
                        MapLocationDot(tint: MovesPalette.place, isSelected: true)
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(currentDate, format: .dateTime.hour().minute().second())
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Slider(value: $progress, in: 0.05...0.95)
                    Text(String(localized: "Drag to pick the moment to split."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding(16)
            .navigationTitle(String(localized: "Split"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Split"), action: split)
                }
            }
            .onChange(of: progress) { _, _ in
                camera = .region(
                    MKCoordinateRegion(
                        center: currentCoordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    )
                )
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var spanStart: Date {
        switch target {
        case .visit(let visit):
            return visit.arrivalDate
        case .move(let move):
            return move.startDate
        }
    }

    private var spanEnd: Date {
        switch target {
        case .visit(let visit):
            if let departure = visit.departureDate, departure > visit.arrivalDate {
                return departure
            }
            return visit.outgoingMoves.map(\.startDate).min() ?? visit.arrivalDate.addingTimeInterval(60)
        case .move(let move):
            return move.endDate
        }
    }

    private var currentDate: Date {
        let span = spanEnd.timeIntervalSince(spanStart)
        return spanStart.addingTimeInterval(span * progress)
    }

    private var currentCoordinate: CLLocationCoordinate2D {
        Self.coordinate(for: target, progress: progress)
    }

    private func split() {
        switch target {
        case .visit(let visit):
            editController.applySplitVisit(visit, at: currentDate)
        case .move(let move):
            editController.applySplitMove(move, at: currentDate)
        }
        dismiss()
    }

    private static func coordinate(for target: Target, progress: Double) -> CLLocationCoordinate2D {
        switch target {
        case .visit(let visit):
            return visit.coordinate
        case .move(let move):
            let coordinates = TimelineLocator.displayedCoordinates(for: move)
            return TimelineLocator.interpolate(along: coordinates, progress: progress)
                ?? move.startPlace?.coordinate
                ?? move.endPlace?.coordinate
                ?? CLLocationCoordinate2D()
        }
    }
}
