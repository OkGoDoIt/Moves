import SwiftUI

/// Coverage layer shown on the Map tab.
enum MapCoverageLayer: String, CaseIterable, Identifiable, Sendable {
    case routes
    case heat
    case fog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routes: return String(localized: "Routes")
        case .heat: return String(localized: "Heat")
        case .fog: return String(localized: "Fog")
        }
    }
}

/// Mode filter chips and Routes / Heat / Fog layer picker.
struct MapLayerChips: View {
    @Binding var layer: MapCoverageLayer
    @Binding var enabledModes: Set<TransportMode>
    let presentModes: [TransportMode]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            layerPicker
            if !presentModes.isEmpty, layer == .routes {
                modeChips
            }
        }
    }

    private var layerPicker: some View {
        HStack(spacing: 0) {
            ForEach(MapCoverageLayer.allCases) { candidate in
                Button {
                    layer = candidate
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: candidate == layer ? .semibold : .medium, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(candidate == layer ? Color.primary : Color.secondary)
                        .background {
                            if candidate == layer {
                                Capsule().fill(.thinMaterial)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(candidate == layer ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Map layers"))
    }

    private var modeChips: some View {
        HStack(spacing: 6) {
            ForEach(presentModes, id: \.self) { mode in
                let isOn = enabledModes.isEmpty || enabledModes.contains(mode)
                Button {
                    toggle(mode)
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : MovesPalette.transport(mode))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(isOn ? MovesPalette.transport(mode) : Color.clear)
                        )
                        .overlay {
                            Circle()
                                .stroke(MovesPalette.transport(mode).opacity(isOn ? 0 : 0.55), lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel(String(localized: "How you moved"))
    }

    private func toggle(_ mode: TransportMode) {
        var current = enabledModes.isEmpty ? Set(presentModes) : enabledModes
        if current.contains(mode) {
            current.remove(mode)
            if current.isEmpty {
                current = Set(presentModes)
            }
        } else {
            current.insert(mode)
        }
        enabledModes = current
    }
}
