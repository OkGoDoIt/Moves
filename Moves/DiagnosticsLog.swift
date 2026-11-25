import Foundation
import OSLog

/// Copies the app's own log lines into a small rolling file in the App Group container.
///
/// A build under test can then be read back from a Mac (`devicectl device copy from`)
/// without a sysdiagnose. Only lines this app logged under its own subsystem are kept, in
/// the form the code logged them: counts, states, and durations. Values the code marked
/// private stay redacted, so no coordinates or place names reach the file.
actor DiagnosticsLog {
    static let shared = DiagnosticsLog()

    /// The file rolls over to `moves.1.log` at this size, so at most two files exist.
    private static let maximumBytes = 2_000_000
    private static let exportInterval: Duration = .seconds(300)

    /// Entries after this moment have not been written yet.
    private var cursor = Date().addingTimeInterval(-120)
    private var timer: Task<Void, Never>?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return formatter
    }()

    static var directoryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: MovesAppIdentity.appGroupIdentifier)?
            .appendingPathComponent("Library/Caches/Diagnostics", isDirectory: true)
    }

    /// Marks a launch in the file and keeps the file current while the process lives.
    func start() {
        guard timer == nil else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        append(["\(formatter.string(from: .now)) ---- launch, version \(version) build \(build) ----"])
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.exportInterval)
                await self?.export()
            }
        }
    }

    /// Writes every line logged since the last export.
    func export() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let predicate = NSPredicate(format: "subsystem == %@", MovesAppIdentity.bundleIdentifier)
        guard let entries = try? store.getEntries(at: store.position(date: cursor), matching: predicate) else {
            return
        }
        var lines: [String] = []
        var newest = cursor
        for case let entry as OSLogEntryLog in entries where entry.date > cursor {
            lines.append(
                "\(formatter.string(from: entry.date)) [\(entry.category)] \(Self.name(of: entry.level)): \(entry.composedMessage)"
            )
            newest = max(newest, entry.date)
        }
        guard !lines.isEmpty else { return }
        cursor = newest
        append(lines)
    }

    private func append(_ lines: [String]) {
        guard let directory = Self.directoryURL else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("moves.log")
        let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > Self.maximumBytes {
            let previous = directory.appendingPathComponent("moves.1.log")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: file, to: previous)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "log"
        @unknown default: "log"
        }
    }
}
