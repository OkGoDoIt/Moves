import Foundation
import zlib

/// Reads Google Takeout zip archives without a third-party ZIP library.
///
/// Supports stored (method 0) and deflate (method 8) entries. Encrypted and
/// Zip64 archives are rejected. Large entries such as `Records.json` are
/// inflated to a temporary file so the uncompressed ~300 MiB never sits in RAM
/// as one `Data` blob.
enum GoogleTimelineZipReader {
    struct Entry: Sendable {
        var path: String
        var method: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64

        var fileName: String {
            (path as NSString).lastPathComponent
        }

        /// Semantic months, Records.json, and on-device Timeline.json. Skips Settings and HTML.
        var isTimelineFile: Bool {
            GoogleTimelineZipReader.isTimelinePath(path)
        }
    }

    static func isTimelinePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "settings.json" || name == "archive_browser.html" || name == ".ds_store" {
            return false
        }
        if name == "records.json" || name == "timeline.json" {
            return true
        }
        let lowered = path.lowercased()
        if name.hasSuffix(".json") && lowered.contains("semantic location history") {
            return true
        }
        return name.range(of: #"^\d{4}_[a-z]+\.json$"#, options: [.regularExpression]) != nil
    }

    static func timelineEntries(in zipURL: URL) throws -> [Entry] {
        try entries(in: zipURL).filter(\.isTimelineFile)
    }

    static func entries(in zipURL: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw GoogleTimelineImportError.corruptZip }

        let tailLength = Int(min(fileSize, UInt64(65_535 + 22)))
        try handle.seek(toOffset: fileSize - UInt64(tailLength))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard let eocd = findEOCD(in: tail) else {
            throw GoogleTimelineImportError.corruptZip
        }
        let cdSize = UInt64(eocd.centralDirectorySize)
        let cdOffset = UInt64(eocd.centralDirectoryOffset)
        try handle.seek(toOffset: cdOffset)
        let central = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard central.count == Int(cdSize) else { throw GoogleTimelineImportError.corruptZip }

        var entries: [Entry] = []
        var cursor = 0
        while cursor + 46 <= central.count {
            guard central[cursor] == 0x50, central[cursor + 1] == 0x4B,
                  central[cursor + 2] == 0x01, central[cursor + 3] == 0x02 else {
                break
            }
            let flags = central.u16(cursor + 8)
            if flags & 1 != 0 {
                throw GoogleTimelineImportError.corruptZip
            }
            let method = central.u16(cursor + 10)
            let compressed = UInt64(central.u32(cursor + 20))
            let uncompressed = UInt64(central.u32(cursor + 24))
            let nameLength = Int(central.u16(cursor + 28))
            let extraLength = Int(central.u16(cursor + 30))
            let commentLength = Int(central.u16(cursor + 32))
            let localOffset = UInt64(central.u32(cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= central.count else { throw GoogleTimelineImportError.corruptZip }
            let path = String(data: central.subdata(in: nameStart..<nameEnd), encoding: .utf8)
                ?? String(data: central.subdata(in: nameStart..<nameEnd), encoding: .isoLatin1)
                ?? "entry"
            entries.append(
                Entry(
                    path: path,
                    method: method,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset
                )
            )
            cursor = nameEnd + extraLength + commentLength
        }
        return entries
    }

    /// Inflates `entry` to `destination`. Creates parent folders as needed.
    static func extract(_ entry: Entry, from zipURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = try compressedPayload(entry, from: zipURL)
        switch entry.method {
        case 0:
            try payload.write(to: destination, options: .atomic)
        case 8:
            let inflated = try inflateRaw(payload, expectedSize: Int(entry.uncompressedSize))
            try inflated.write(to: destination, options: .atomic)
        default:
            throw GoogleTimelineImportError.corruptZip
        }
    }

    /// Inflates a small entry (semantic months) into memory.
    static func extractData(_ entry: Entry, from zipURL: URL) throws -> Data {
        let payload = try compressedPayload(entry, from: zipURL)
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflateRaw(payload, expectedSize: Int(entry.uncompressedSize))
        default:
            throw GoogleTimelineImportError.corruptZip
        }
    }

    private static func compressedPayload(_ entry: Entry, from zipURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw GoogleTimelineImportError.corruptZip
        }
        guard header[0] == 0x50, header[1] == 0x4B, header[2] == 0x03, header[3] == 0x04 else {
            throw GoogleTimelineImportError.corruptZip
        }
        let nameLength = Int(header.u16(26))
        let extraLength = Int(header.u16(28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength))
        if entry.compressedSize > 200_000_000 {
            throw GoogleTimelineImportError.recordsTooLargeToBuffer
        }
        let payload = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard payload.count == Int(entry.compressedSize) else {
            throw GoogleTimelineImportError.corruptZip
        }
        return payload
    }

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GoogleTimelineImportError.corruptZip }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(max(expectedSize, 1))
        let chunk = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunk)

        try input.withUnsafeBytes { srcBuffer in
            guard let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: src)
            stream.avail_in = uInt(input.count)
            while true {
                let result: Int32 = outBuffer.withUnsafeMutableBytes { dest in
                    stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: outBuffer.prefix(produced))
                }
                if result == Z_STREAM_END {
                    break
                }
                if result != Z_OK && result != Z_BUF_ERROR {
                    throw GoogleTimelineImportError.corruptZip
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw GoogleTimelineImportError.corruptZip
                }
            }
        }
        return output
    }

    private struct EOCD {
        var centralDirectorySize: UInt32
        var centralDirectoryOffset: UInt32
    }

    private static func findEOCD(in tail: Data) -> EOCD? {
        guard tail.count >= 22 else { return nil }
        let bytes = tail
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return EOCD(
                    centralDirectorySize: bytes.u32(index + 12),
                    centralDirectoryOffset: bytes.u32(index + 16)
                )
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
