import Photos
import SwiftData
import SwiftUI
import UIKit

/// Up to four visit thumbnails plus a "+N" remainder, shown on storyline place rows.
struct VisitPhotoThumbnailStrip: View {
    let attachments: [PhotoAttachment]
    var maximumVisibleCount = 4

    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showOnVisits = true
    @State private var isShowingGrid = false
    @State private var viewerIndex: Int?

    private var ordered: [PhotoAttachment] {
        attachments.sorted { $0.capturedAt < $1.capturedAt }
    }

    private var visible: [PhotoAttachment] {
        Array(ordered.prefix(maximumVisibleCount))
    }

    private var overflowCount: Int {
        max(ordered.count - maximumVisibleCount, 0)
    }

    var body: some View {
        if showOnVisits, !ordered.isEmpty {
            HStack(spacing: 6) {
                ForEach(visible, id: \.assetLocalIdentifier) { attachment in
                    Button {
                        if let index = ordered.firstIndex(where: { $0.assetLocalIdentifier == attachment.assetLocalIdentifier }) {
                            viewerIndex = index
                        }
                    } label: {
                        PhotoAssetThumbnail(
                            identifier: attachment.assetLocalIdentifier,
                            cornerRadius: 8
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(attachment.capturedAt, format: .dateTime.hour().minute()))
                }

                if overflowCount > 0 {
                    Button {
                        isShowingGrid = true
                    } label: {
                        Text("+\(overflowCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(MovesPalette.place.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(overflowCount) more photos"))
                }
            }
            .padding(.top, 6)
            .sheet(isPresented: $isShowingGrid) {
                VisitPhotoGridView(attachments: ordered)
            }
            .fullScreenCover(item: viewerItem) { item in
                VisitPhotoViewer(attachments: ordered, startIndex: item.index)
            }
        }
    }

    private var viewerItem: Binding<PhotoViewerItem?> {
        Binding(
            get: {
                viewerIndex.map(PhotoViewerItem.init(index:))
            },
            set: { newValue in
                viewerIndex = newValue?.index
            }
        )
    }
}

private struct PhotoViewerItem: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Horizontal read-only thumbnails for photos in a date range.
///
/// Named trip detail presents this for visit attachments in the trip interval.
/// Does not copy or own the attachments.
struct PhotoAttachmentRangeStrip: View {
    let attachments: [PhotoAttachment]
    var thumbnailSize: CGFloat = 72

    @AppStorage(PhotoLibrarySettings.showOnVisitsKey) private var showOnVisits = true
    @State private var viewerIndex: Int?

    private var ordered: [PhotoAttachment] {
        attachments.sorted { $0.capturedAt < $1.capturedAt }
    }

    var body: some View {
        if ordered.isEmpty || !showOnVisits {
            Text(String(localized: "No photos in this range"))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ordered.enumerated()), id: \.element.assetLocalIdentifier) { index, attachment in
                        Button {
                            viewerIndex = index
                        } label: {
                            PhotoAssetThumbnail(
                                identifier: attachment.assetLocalIdentifier,
                                cornerRadius: 10
                            )
                            .frame(width: thumbnailSize, height: thumbnailSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(attachment.capturedAt, format: .dateTime.hour().minute()))
                    }
                }
            }
            .fullScreenCover(item: viewerItem) { item in
                VisitPhotoViewer(attachments: ordered, startIndex: item.index)
            }
        }
    }

    private var viewerItem: Binding<PhotoViewerItem?> {
        Binding(
            get: { viewerIndex.map(PhotoViewerItem.init(index:)) },
            set: { viewerIndex = $0?.index }
        )
    }
}

/// Square still loaded from PhotoKit for a local identifier. Empty if Limited Library excludes it.
struct PhotoAssetThumbnail: View {
    let identifier: String
    var cornerRadius: CGFloat = 8
    var quality: PHImageRequestOptionsDeliveryMode = .fastFormat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: identifier) {
            let scale = UITraitCollection.current.displayScale
            let size = CGSize(width: 88 * scale, height: 88 * scale)
            image = await PhotoThumbnailLoader.image(
                for: identifier,
                targetSize: size,
                quality: quality
            )
        }
    }
}

/// Read-only grid of every photo on a visit.
struct VisitPhotoGridView: View {
    let attachments: [PhotoAttachment]
    @Environment(\.dismiss) private var dismiss
    @State private var viewerIndex: Int?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(attachments.enumerated()), id: \.element.assetLocalIdentifier) { index, attachment in
                        Button {
                            viewerIndex = index
                        } label: {
                            PhotoAssetThumbnail(
                                identifier: attachment.assetLocalIdentifier,
                                cornerRadius: 6
                            )
                            .aspectRatio(1, contentMode: .fill)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: viewerBinding) { item in
                VisitPhotoViewer(attachments: attachments, startIndex: item.index)
            }
        }
    }

    private var viewerBinding: Binding<PhotoViewerItem?> {
        Binding(
            get: { viewerIndex.map(PhotoViewerItem.init(index:)) },
            set: { viewerIndex = $0?.index }
        )
    }
}

/// Full-screen, read-only `PHAsset` viewer. No edit, share, or delete controls.
struct VisitPhotoViewer: View {
    let attachments: [PhotoAttachment]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var index: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(String(localized: "Close"))

                Spacer()

                if let attachment = attachments[safe: index] {
                    Text(attachment.capturedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .padding(20)
        }
        .overlay(alignment: .bottom) {
            if attachments.count > 1 {
                HStack {
                    Button {
                        index = max(index - 1, 0)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .disabled(index == 0)

                    Spacer()

                    Text("\(index + 1) of \(attachments.count)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer()

                    Button {
                        index = min(index + 1, attachments.count - 1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .disabled(index >= attachments.count - 1)
                }
                .padding(24)
            }
        }
        .task(id: index) {
            await loadCurrent()
        }
        .onAppear {
            index = min(max(startIndex, 0), max(attachments.count - 1, 0))
        }
        .statusBarHidden(true)
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 80 {
                    dismiss()
                }
            }
        )
    }

    private func loadCurrent() async {
        image = nil
        guard let identifier = attachments[safe: index]?.assetLocalIdentifier else { return }
        image = await PhotoThumbnailLoader.image(
            for: identifier,
            targetSize: PHImageManagerMaximumSize,
            quality: .highQualityFormat
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
