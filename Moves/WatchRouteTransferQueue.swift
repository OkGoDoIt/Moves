import Foundation

/// Serializes durable Watch route delivery across repeated flushes and launches.
/// WatchConnectivity owns transfers after submission, including while unreachable.
struct WatchRouteTransferQueue {
    private var submittedFile: URL?
    private var retryAfter: Date?

    mutating func nextFile(
        storedFiles: [URL],
        outstandingFiles: [URL],
        now: Date = .now
    ) -> URL? {
        guard submittedFile == nil, outstandingFiles.isEmpty,
              retryAfter.map({ now >= $0 }) ?? true else { return nil }
        let file = storedFiles
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "manifest.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        submittedFile = file
        return file
    }

    mutating func finished(_ file: URL, succeeded: Bool, now: Date = .now) {
        if submittedFile == file { submittedFile = nil }
        // Keep failed payloads on disk. A later activation/location event retries,
        // without a busy retry loop while the phone is unavailable.
        if !succeeded { retryAfter = now.addingTimeInterval(60) }
    }
}
