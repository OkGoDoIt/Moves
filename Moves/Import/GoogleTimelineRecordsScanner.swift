import Foundation

/// Streams the `locations` array of a Takeout `Records.json` without loading
/// the file into memory. Each object is decoded on its own; callers must never
/// pass this file through `JSONSerialization` as a whole (~308 MiB here, over
/// 1 GB on some Takeouts).
enum GoogleTimelineRecordsScanner {
    /// Walks every usable fix in `url`. Return `false` from `body` to stop early.
    ///
    /// - Parameters:
    ///   - url: Path to `Records.json` or any JSON object whose `locations`
    ///     value is an array of record objects.
    ///   - progress: `(pointsEmitted, bytesRead)` on the caller's thread.
    ///   - body: Returning `false` stops the scan.
    /// - Returns: Number of objects that produced a `LocationLogPoint`.
    @discardableResult
    static func forEachRecord(
        at url: URL,
        progress: ((Int, Int64) -> Void)? = nil,
        body: (LocationLogPoint) throws -> Bool
    ) throws -> Int {
        let stream = try InputStream(url: url).unwrapped(url.lastPathComponent)
        var emitted = 0
        _ = try forEachObject(in: stream, arrayKey: "locations", progress: progress) { objectData in
            guard let point = GoogleTimelineParser.parseRecordObject(data: objectData) else {
                return true
            }
            emitted += 1
            return try body(point)
        }
        return emitted
    }

    /// Same scan over an in-memory payload. Use only for small fixtures.
    @discardableResult
    static func forEachRecord(
        in data: Data,
        body: (LocationLogPoint) throws -> Bool
    ) throws -> Int {
        let stream = InputStream(data: data)
        var emitted = 0
        _ = try forEachObject(in: stream, arrayKey: "locations", progress: nil) { objectData in
            guard let point = GoogleTimelineParser.parseRecordObject(data: objectData) else {
                return true
            }
            emitted += 1
            return try body(point)
        }
        return emitted
    }

    /// Brace-matches each object in a JSON array. Structural scanning is
    /// byte-wise (JSON delimiters are ASCII) so UTF-8 string contents are safe.
    @discardableResult
    static func forEachObject(
        in stream: InputStream,
        arrayKey: String?,
        progress: ((Int, Int64) -> Void)? = nil,
        body: (Data) throws -> Bool
    ) throws -> Int {
        stream.open()
        defer { stream.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var consumed = 0
        var bytesRead: Int64 = 0
        var objects = 0
        var emitted = 0
        var foundArray = arrayKey == nil
        let keyBytes = arrayKey.map { Array("\"\($0)\"".utf8) }

        func fill() throws -> Bool {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = stream.read(&chunk, maxLength: chunk.count)
            if n < 0 {
                throw GoogleTimelineImportError.unreadableFile("Records.json")
            }
            if n == 0 { return false }
            buffer.append(contentsOf: chunk.prefix(n))
            bytesRead += Int64(n)
            return true
        }

        func byte(_ index: Int) -> UInt8 {
            buffer[buffer.startIndex + index]
        }

        func ensure(_ needed: Int) throws -> Bool {
            while buffer.count - consumed < needed {
                if try fill() == false { return false }
            }
            return buffer.count - consumed >= needed
        }

        if let keyBytes {
            search: while true {
                guard try ensure(keyBytes.count) else {
                    throw GoogleTimelineImportError.notGoogleTimeline
                }
                let lastStart = buffer.count - keyBytes.count
                if consumed <= lastStart {
                    var matchAt: Int?
                    for index in consumed...lastStart {
                        var ok = true
                        for (offset, expected) in keyBytes.enumerated() where buffer[index + offset] != expected {
                            ok = false
                            break
                        }
                        if ok {
                            matchAt = index
                            break
                        }
                    }
                    if let matchAt {
                        consumed = matchAt + keyBytes.count
                        foundArray = true
                        break search
                    }
                    consumed = lastStart
                }
                if try fill() == false {
                    throw GoogleTimelineImportError.notGoogleTimeline
                }
            }
        }

        // Advance to the array's opening '['.
        while true {
            guard try ensure(1) else {
                throw GoogleTimelineImportError.notGoogleTimeline
            }
            let current = byte(consumed)
            consumed += 1
            if current == 0x5B { // [
                break
            }
            if current == 0x7B && !foundArray { // { without a locations key
                continue
            }
        }

        while true {
            while true {
                guard try ensure(1) else { return emitted }
                let current = byte(consumed)
                if current == 0x20 || current == 0x0A || current == 0x0D || current == 0x09 || current == 0x2C {
                    consumed += 1
                    continue
                }
                break
            }
            guard try ensure(1) else { return emitted }
            let next = byte(consumed)
            if next == 0x5D { // ]
                return emitted
            }
            guard next == 0x7B else {
                consumed += 1
                continue
            }

            guard let objectData = try extractObject(buffer: &buffer, consumed: &consumed, fill: fill) else {
                return emitted
            }
            objects += 1
            emitted += 1
            let keepGoing = try body(objectData)
            if objects.isMultiple(of: 2_000) {
                progress?(emitted, bytesRead)
            }
            if buffer.count > 256 * 1024 && consumed > 128 * 1024 {
                buffer.removeSubrange(..<(buffer.startIndex + consumed))
                consumed = 0
            }
            if !keepGoing {
                return emitted
            }
        }
    }

    private static func extractObject(
        buffer: inout Data,
        consumed: inout Int,
        fill: () throws -> Bool
    ) throws -> Data? {
        var depth = 0
        var inString = false
        var escaped = false
        let start = consumed

        while true {
            if consumed >= buffer.count {
                if try fill() == false {
                    return nil
                }
            }
            let current = buffer[buffer.startIndex + consumed]
            consumed += 1

            if inString {
                if escaped {
                    escaped = false
                    continue
                }
                if current == 0x5C { // \
                    escaped = true
                    continue
                }
                if current == 0x22 { // "
                    inString = false
                }
                continue
            }

            switch current {
            case 0x22:
                inString = true
            case 0x7B:
                depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 {
                    return Data(buffer[(buffer.startIndex + start)..<(buffer.startIndex + consumed)])
                }
            default:
                break
            }
        }
    }
}

private extension Optional where Wrapped == InputStream {
    func unwrapped(_ name: String) throws -> InputStream {
        guard let self else {
            throw GoogleTimelineImportError.unreadableFile(name)
        }
        return self
    }
}
