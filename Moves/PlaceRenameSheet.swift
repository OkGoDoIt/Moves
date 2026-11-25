import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// Rename a visit: typed name plus nearby learned places and Apple POIs.
///
/// A stay that still goes by its street address opens as "Name this place": the field
/// starts empty so the nearby list shows everything around, and one tap on a suggestion
/// names the stay.
struct PlaceRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let visit: VisitPlace
    var focusesNearby: Bool
    var editController: TimelineEditController
    var searcher: any LocalPlaceSearching

    @State private var draftName: String
    @State private var namingModel: PlaceNamingModel
    private let isNaming: Bool
    private let initialName: String

    init(
        visit: VisitPlace,
        focusesNearby: Bool = false,
        editController: TimelineEditController,
        searcher: any LocalPlaceSearching = MapKitLocalPlaceSearcher()
    ) {
        self.visit = visit
        self.focusesNearby = focusesNearby
        self.editController = editController
        self.searcher = searcher
        let isNaming = TimelinePlaceNaming.needsName(visit)
        self.isNaming = isNaming
        let initialName = isNaming ? "" : (visit.userLabel ?? visit.knownPlace?.name ?? visit.autoLabel ?? "")
        self.initialName = initialName
        _draftName = State(initialValue: initialName)
        _namingModel = State(initialValue: PlaceNamingModel(searcher: searcher))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(isNaming ? visit.displayTitle : String(localized: "Name"), text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveTypedName)
                }

                // The field above is the search: the list narrows as the person types.
                PlaceChoiceSections(
                    model: namingModel,
                    query: namingModel.sheetQuery,
                    showsUseTyped: false
                ) { candidate in
                    editController.applyCandidate(candidate, to: visit)
                    dismiss()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { saveTypedName() }
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task(id: visit.id) {
                await namingModel.prepare(
                    near: visit.coordinate,
                    accuracy: visit.horizontalAccuracy,
                    modelContext: modelContext
                )
            }
            .onChange(of: draftName) { _, text in
                // An unedited current name lists everything nearby; edits narrow the list.
                namingModel.sheetQuery = text == initialName ? "" : text
            }
            .onDisappear { namingModel.cancel() }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        if isNaming { return String(localized: "Name this place") }
        return focusesNearby ? String(localized: "Nearby places") : String(localized: "Rename")
    }

    private func saveTypedName() {
        editController.applyRename(to: visit, name: draftName)
        dismiss()
    }
}
