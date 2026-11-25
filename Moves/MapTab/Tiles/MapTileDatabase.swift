import Foundation
import SQLite3

/// Per-month facts the Map reads without touching tiles: how many trips and stays a range has,
/// where it is, and the scrubber's moving minutes.
struct MapMonthSummary: Codable, Equatable, Sendable {
    var bucket: Int
    /// Drawable trips per `TransportMode.allCases` index.
    var tripsByMode: [Int] = Array(repeating: 0, count: TransportMode.allCases.count)
    var stays = 0
    /// Trips and stays by day of month (index 0 is the 1st), for ranges that end mid-month.
    var dayTrips: [Int] = Array(repeating: 0, count: 31)
    var dayStays: [Int] = Array(repeating: 0, count: 31)
    /// Moving minutes of every move, drawable or not, by mode index then day of month.
    var dayMinutesByMode: [[Double]] = Array(repeating: Array(repeating: 0, count: 31), count: TransportMode.allCases.count)
    /// Map-point bounds of everything drawn: minX, minY, maxX, maxY.
    var bounds: [Double]?
    /// The last place anything happened: x, y, and when.
    var latest: [Double]?
    var excludedTrips = 0

    var trips: Int { tripsByMode.reduce(0, +) }
}

/// The tile pyramid on disk: one SQLite file in Caches. It is a rebuildable cache, so any format
/// change, foreign store, or unreadable file is simply wiped.
///
/// One file rather than per-level files: a month's records at every level, its swap into the
/// all-time sum, and its signature commit in one transaction, so a kill mid-build
/// leaves either the old month or the new one and never half of each. WAL lets the Map read while
/// the builder writes; a connection is used from one thread at a time behind its lock.
final class MapTileDatabase: @unchecked Sendable {
    /// Bump whenever what the builder stores changes: tile rules, levels, encoding, or which
    /// trips and fixes count.
    static let formatVersion = 3

    let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MapTiles", isDirectory: true)
    }

    /// Opens (creating if needed) the pyramid for `storeIdentity`. A file built for another store or
    /// format version is replaced by an empty one.
    init(url: URL, storeIdentity: String) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try open()
        let version = meta("format"), identity = meta("store")
        if version != String(Self.formatVersion) || identity != storeIdentity {
            close()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            try open()
            try setMeta("format", String(Self.formatVersion))
            try setMeta("store", storeIdentity)
        }
    }

    deinit { close() }

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw MapTileDatabaseError.open
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS tiles(level INTEGER NOT NULL, bucket INTEGER NOT NULL, x INTEGER NOT NULL,
                y INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(level, bucket, x, y)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS months(bucket INTEGER PRIMARY KEY, signature TEXT NOT NULL, summary BLOB NOT NULL);
            """)
    }

    private func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: Plumbing

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MapTileDatabaseError.sql(lastError) }
    }

    private var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MapTileDatabaseError.sql(lastError)
        }
        statements[sql] = statement
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer, _ values: [Any]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as Int: sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any] = []) throws {
        let statement = try statement(sql)
        bind(statement, values)
        let result = sqlite3_step(statement)
        sqlite3_reset(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw MapTileDatabaseError.sql(lastError) }
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = try? statement("SELECT value FROM meta WHERE key = ?") else { return nil }
        bind(statement, [key])
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func setMeta(_ key: String, _ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [key, value])
    }

    // MARK: Months

    func monthSignatures() -> [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Int: String] = [:]
        guard let statement = try? statement("SELECT bucket, signature FROM months") else { return result }
        defer { sqlite3_reset(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                result[Int(sqlite3_column_int64(statement, 0))] = String(cString: text)
            }
        }
        return result
    }

    func summaries() -> [MapMonthSummary] {
        lock.lock()
        defer { lock.unlock() }
        var result: [MapMonthSummary] = []
        guard let statement = try? statement("SELECT summary FROM months ORDER BY bucket") else { return result }
        defer { sqlite3_reset(statement) }
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = try? decoder.decode(MapMonthSummary.self, from: blob(statement, 0)) {
                result.append(summary)
            }
        }
        return result
    }

    // MARK: Tiles

    struct Row: Sendable {
        let bucket: Int
        let x: Int
        let y: Int
        let data: Data
    }

    /// Records of `buckets` at `level` inside the tile ranges, plus the level's long-segment
    /// records for those buckets.
    func records(level: Int, buckets: [Int], x: ClosedRange<Int>, y: ClosedRange<Int>) -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        var rows: [Row] = []
        guard let statement = try? statement(
            "SELECT x, y, data FROM tiles WHERE level = ? AND bucket = ? AND ((x BETWEEN ? AND ? AND y BETWEEN ? AND ?) OR (x = -1 AND y = -1))"
        ) else { return rows }
        for bucket in buckets {
            sqlite3_reset(statement)
            bind(statement, [level, bucket, x.lowerBound, x.upperBound, y.lowerBound, y.upperBound])
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Row(bucket: bucket, x: Int(sqlite3_column_int64(statement, 0)),
                                y: Int(sqlite3_column_int64(statement, 1)), data: blob(statement, 2)))
            }
        }
        sqlite3_reset(statement)
        return rows
    }

    /// Month records at `level` for one tile range, for tapping a route.
    func monthRecords(level: Int, months: ClosedRange<Int>, x: ClosedRange<Int>, y: ClosedRange<Int>) -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        var rows: [Row] = []
        guard let statement = try? statement("""
            SELECT bucket, x, y, data FROM tiles WHERE level = ? AND bucket BETWEEN ? AND ?
            AND ((x BETWEEN ? AND ? AND y BETWEEN ? AND ?) OR (x = -1 AND y = -1))
            """) else { return rows }
        defer { sqlite3_reset(statement) }
        bind(statement, [level, months.lowerBound, months.upperBound, x.lowerBound, x.upperBound, y.lowerBound, y.upperBound])
        while sqlite3_step(statement) == SQLITE_ROW {
            let bucket = Int(sqlite3_column_int64(statement, 0))
            guard MapTileBucket.isMonth(bucket) else { continue }
            rows.append(Row(bucket: bucket, x: Int(sqlite3_column_int64(statement, 1)),
                            y: Int(sqlite3_column_int64(statement, 2)), data: blob(statement, 3)))
        }
        return rows
    }

    /// One built month, ready to commit.
    struct MonthBuild: Sendable {
        let bucket: Int
        let signature: String
        let summary: MapMonthSummary
        let tiles: [MapTileKey: MapTileContent]
    }

    /// Replaces each month's records, swaps them in the all-time sum, and records their
    /// signatures, all in one transaction.
    func commit(_ months: [MonthBuild]) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            struct AggregateKey: Hashable { let bucket: Int; let tile: MapTileKey }
            var removed: [AggregateKey: MapTileContent] = [:]
            var added: [AggregateKey: MapTileContent] = [:]
            let select = "SELECT level, x, y, data FROM tiles WHERE bucket = ?"
            let encoder = JSONEncoder()
            for month in months {
                let statement = try statement(select)
                bind(statement, [month.bucket])
                var old: [(MapTileKey, Data)] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let key = MapTileKey(level: Int(sqlite3_column_int64(statement, 0)), x: Int(sqlite3_column_int64(statement, 1)),
                                         y: Int(sqlite3_column_int64(statement, 2)))
                    old.append((key, blob(statement, 3)))
                }
                sqlite3_reset(statement)
                for (key, data) in old {
                    guard let record = MapTileCodec.decode(data) else { continue }
                    removed[AggregateKey(bucket: MapTileBucket.allTime, tile: key), default: MapTileContent()]
                        .merge(MapTileCodec.content(of: record))
                }
                try run("DELETE FROM tiles WHERE bucket = ?", [month.bucket])
                for (key, content) in month.tiles where !content.isEmpty {
                    try run("INSERT INTO tiles(level, bucket, x, y, data) VALUES(?, ?, ?, ?, ?)",
                            [key.level, month.bucket, key.x, key.y, MapTileCodec.encode(content, absolute: key.isLong, keepTrips: true, compress: true)])
                    added[AggregateKey(bucket: MapTileBucket.allTime, tile: key), default: MapTileContent()].merge(content)
                }
                try run("INSERT OR REPLACE INTO months(bucket, signature, summary) VALUES(?, ?, ?)",
                        [month.bucket, month.signature, try encoder.encode(month.summary)])
            }
            for key in Set(removed.keys).union(added.keys) {
                let statement = try statement("SELECT data FROM tiles WHERE level = ? AND bucket = ? AND x = ? AND y = ?")
                bind(statement, [key.tile.level, key.bucket, key.tile.x, key.tile.y])
                var current = MapTileContent()
                if sqlite3_step(statement) == SQLITE_ROW, let record = MapTileCodec.decode(blob(statement, 0)) {
                    current = MapTileCodec.content(of: record)
                }
                sqlite3_reset(statement)
                if let removed = removed[key] { current.merge(removed, sign: -1) }
                if let added = added[key] { current.merge(added) }
                if current.isEmpty {
                    try run("DELETE FROM tiles WHERE level = ? AND bucket = ? AND x = ? AND y = ?",
                            [key.tile.level, key.bucket, key.tile.x, key.tile.y])
                } else {
                    try run("INSERT OR REPLACE INTO tiles(level, bucket, x, y, data) VALUES(?, ?, ?, ?, ?)",
                            [key.tile.level, key.bucket, key.tile.x, key.tile.y,
                             MapTileCodec.encode(current, absolute: key.tile.isLong, keepTrips: false, compress: true)])
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Forgets a month that no longer has anything in it.
    func removeMonth(_ bucket: Int) throws {
        try commit([MonthBuild(bucket: bucket, signature: "", summary: MapMonthSummary(bucket: bucket), tiles: [:])])
        lock.lock()
        defer { lock.unlock() }
        try run("DELETE FROM months WHERE bucket = ?", [bucket])
    }

    /// Replaces the imported undated coverage and records what it was built from.
    func replaceUndated(_ tiles: [MapTileKey: MapTileContent], signature: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM tiles WHERE bucket = ?", [MapTileBucket.undated])
            for (key, content) in tiles where !content.isEmpty {
                try run("INSERT INTO tiles(level, bucket, x, y, data) VALUES(?, ?, ?, ?, ?)",
                        [key.level, MapTileBucket.undated, key.x, key.y, MapTileCodec.encode(content, absolute: key.isLong, keepTrips: false, compress: true)])
            }
            try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", ["undated", signature])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Bytes on disk, including the write-ahead log.
    func sizeOnDisk() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Record count per bucket kind, for logs and tests.
    func recordCount(bucket: Int? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sql = bucket == nil ? "SELECT count(*) FROM tiles" : "SELECT count(*) FROM tiles WHERE bucket = ?"
        guard let statement = try? statement(sql) else { return 0 }
        defer { sqlite3_reset(statement) }
        if let bucket { bind(statement, [bucket]) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Folds the write-ahead log back into the file once a long build is done.
    func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
}

enum MapTileDatabaseError: Error {
    case open
    case sql(String)
}
