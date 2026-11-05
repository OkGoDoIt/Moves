//
//  MovesZipArchive.swift
//  Moves
//
//  Minimal ZIP packer/unpacker used by the all-in-one timeline export.
//  Packed files use the store method (no compression) so the format stays
//  dependency-free. Unpacking also inflates standard DEFLATE entries so a
//  zip created by Files / Finder can still be restored.
//

import Foundation
import zlib

/// One member of a `.zip` archive.
struct MovesZipFile: Equatable {
    /// Path inside the archive, using `/` separators and no leading slash.
    var path: String
    var data: Data
}

enum MovesZipArchiveError: LocalizedError, Equatable {
    case truncated
    case unsupportedCompression(UInt16)
    case inflateFailed
    case empty

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "The zip file is truncated or unreadable."
        case .unsupportedCompression(let method):
            return "The zip file uses unsupported compression method \(method)."
        case .inflateFailed:
            return "A compressed zip entry could not be inflated."
        case .empty:
            return "The zip file has no readable files."
        }
    }
}

/// Packs and unpacks PKZIP archives without ZIPFoundation.
enum MovesZipArchive {
    private static let localFileHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectorySignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
    private static let utf8Flag: UInt16 = 1 << 11
    private static let storeMethod: UInt16 = 0
    private static let deflateMethod: UInt16 = 8

    /// Builds an uncompressed `.zip` from in-memory files.
    static func pack(_ files: [MovesZipFile]) -> Data {
        var local = Data()
        var central = Data()
        var entryCount: UInt16 = 0

        for file in files where !file.path.isEmpty {
            let nameData = Data(file.path.utf8)
            guard nameData.count <= Int(UInt16.max) else { continue }

            let crc = crc32Checksum(of: file.data)
            let size = UInt32(truncatingIfNeeded: file.data.count)
            let localOffset = UInt32(truncatingIfNeeded: local.count)

            appendLocalFileHeader(
                to: &local,
                name: nameData,
                crc: crc,
                size: size
            )
            local.append(file.data)

            appendCentralDirectoryHeader(
                to: &central,
                name: nameData,
                crc: crc,
                size: size,
                localHeaderOffset: localOffset
            )
            entryCount += 1
        }

        let centralOffset = UInt32(truncatingIfNeeded: local.count)
        let centralSize = UInt32(truncatingIfNeeded: central.count)
        var zip = local
        zip.append(central)
        appendEndOfCentralDirectory(
            to: &zip,
            entryCount: entryCount,
            centralDirectorySize: centralSize,
            centralDirectoryOffset: centralOffset
        )
        return zip
    }

    /// Reads stored and DEFLATE members. Directory entries and Finder metadata are skipped.
    ///
    /// Sizes and checksums come from the central directory, because streaming zips such as
    /// `ditto -c -k` leave them at zero in the local headers. A member that does not match
    /// its recorded size and checksum is treated as damage, never returned as partial data.
    static func unpack(_ data: Data) throws -> [MovesZipFile] {
        let directory = try endOfCentralDirectory(in: data)
        var offset = directory.centralDirectoryOffset
        var files: [MovesZipFile] = []

        for _ in 0..<directory.entryCount {
            guard try readUInt32(data, at: &offset) == centralDirectorySignature else {
                throw MovesZipArchiveError.truncated
            }
            try skip(data, at: &offset, count: 6) // versions, flags
            let method = try readUInt16(data, at: &offset)
            try skip(data, at: &offset, count: 4) // mod time/date
            let crc = try readUInt32(data, at: &offset)
            let compressedSize = Int(try readUInt32(data, at: &offset))
            let uncompressedSize = Int(try readUInt32(data, at: &offset))
            let nameLength = Int(try readUInt16(data, at: &offset))
            let extraLength = Int(try readUInt16(data, at: &offset))
            let commentLength = Int(try readUInt16(data, at: &offset))
            try skip(data, at: &offset, count: 8) // disk, attributes
            let localHeaderOffset = Int(try readUInt32(data, at: &offset))
            let name = try readString(data, at: &offset, length: nameLength)
            try skip(data, at: &offset, count: extraLength + commentLength)

            if shouldSkip(path: name) { continue }

            let payload = try memberPayload(data, atLocalHeader: localHeaderOffset, length: compressedSize)
            let fileData: Data
            switch method {
            case storeMethod:
                fileData = payload
            case deflateMethod:
                fileData = try inflateRaw(payload, expectedSize: uncompressedSize)
            default:
                throw MovesZipArchiveError.unsupportedCompression(method)
            }
            guard fileData.count == uncompressedSize, crc32Checksum(of: fileData) == crc else {
                throw MovesZipArchiveError.truncated
            }

            files.append(MovesZipFile(path: name, data: fileData))
        }

        if files.isEmpty {
            throw MovesZipArchiveError.empty
        }
        return files
    }

    private static func endOfCentralDirectory(in data: Data) throws -> (entryCount: Int, centralDirectoryOffset: Int) {
        let minimumLength = 22
        guard data.count >= minimumLength else { throw MovesZipArchiveError.truncated }
        let earliest = max(data.count - minimumLength - Int(UInt16.max), 0)
        var index = data.count - minimumLength
        while index >= earliest {
            if peekUInt32(data, at: index) == endOfCentralDirectorySignature {
                var offset = index + 10
                let entryCount = Int(try readUInt16(data, at: &offset))
                offset += 4 // central directory size
                let centralDirectoryOffset = Int(try readUInt32(data, at: &offset))
                return (entryCount, centralDirectoryOffset)
            }
            index -= 1
        }
        throw MovesZipArchiveError.truncated
    }

    /// The local header's name and extra lengths can differ from the central directory's.
    private static func memberPayload(_ data: Data, atLocalHeader headerOffset: Int, length: Int) throws -> Data {
        var offset = headerOffset
        guard try readUInt32(data, at: &offset) == localFileHeaderSignature else {
            throw MovesZipArchiveError.truncated
        }
        try skip(data, at: &offset, count: 22) // version through sizes
        let nameLength = Int(try readUInt16(data, at: &offset))
        let extraLength = Int(try readUInt16(data, at: &offset))
        try skip(data, at: &offset, count: nameLength + extraLength)
        return try readData(data, at: &offset, length: length)
    }

    /// True when `data` looks like a PKZIP archive.
    static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4b && (data[2] == 0x03 || data[2] == 0x05 || data[2] == 0x07)
    }

    private static func shouldSkip(path: String) -> Bool {
        if path.hasSuffix("/") { return true }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return true }
        let last = (trimmed as NSString).lastPathComponent
        if last == ".DS_Store" || last.hasPrefix("._") { return true }
        if trimmed.hasPrefix("__MACOSX") { return true }
        if trimmed.contains("..") { return true }
        return false
    }

    private static func appendLocalFileHeader(
        to data: inout Data,
        name: Data,
        crc: UInt32,
        size: UInt32
    ) {
        appendUInt32(&data, localFileHeaderSignature)
        appendUInt16(&data, 20)
        appendUInt16(&data, utf8Flag)
        appendUInt16(&data, storeMethod)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt32(&data, crc)
        appendUInt32(&data, size)
        appendUInt32(&data, size)
        appendUInt16(&data, UInt16(name.count))
        appendUInt16(&data, 0)
        data.append(name)
    }

    private static func appendCentralDirectoryHeader(
        to data: inout Data,
        name: Data,
        crc: UInt32,
        size: UInt32,
        localHeaderOffset: UInt32
    ) {
        appendUInt32(&data, centralDirectorySignature)
        appendUInt16(&data, 20)
        appendUInt16(&data, 20)
        appendUInt16(&data, utf8Flag)
        appendUInt16(&data, storeMethod)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt32(&data, crc)
        appendUInt32(&data, size)
        appendUInt32(&data, size)
        appendUInt16(&data, UInt16(name.count))
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt32(&data, 0)
        appendUInt32(&data, localHeaderOffset)
        data.append(name)
    }

    private static func appendEndOfCentralDirectory(
        to data: inout Data,
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) {
        appendUInt32(&data, endOfCentralDirectorySignature)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, entryCount)
        appendUInt16(&data, entryCount)
        appendUInt32(&data, centralDirectorySize)
        appendUInt32(&data, centralDirectoryOffset)
        appendUInt16(&data, 0)
    }

    static func crc32Checksum(of data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(zlib.crc32(0, bytes.baseAddress, uInt(bytes.count)))
        }
    }

    /// Inflates a ZIP DEFLATE payload (raw RFC 1951, no zlib wrapper).
    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw MovesZipArchiveError.inflateFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(max(expectedSize, input.count * 2), 64 * 1024 * 1024))
        let chunk = 64 * 1024
        var status = Z_OK

        try input.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: Bytef.self).baseAddress else {
                throw MovesZipArchiveError.inflateFailed
            }
            stream.next_in = UnsafeMutablePointer(mutating: sourceBase)
            stream.avail_in = uInt(input.count)

            while status != Z_STREAM_END {
                var buffer = [Bytef](repeating: 0, count: chunk)
                let produced = buffer.withUnsafeMutableBufferPointer { destination -> Int in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunk - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw MovesZipArchiveError.inflateFailed
                }
                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }
                if output.count > expectedSize {
                    throw MovesZipArchiveError.inflateFailed
                }
            }
        }

        return output
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: inout Int) throws -> UInt16 {
        let bytes = try readData(data, at: &offset, length: 2)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: inout Int) throws -> UInt32 {
        let bytes = try readData(data, at: &offset, length: 4)
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    private static func peekUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func readString(_ data: Data, at offset: inout Int, length: Int) throws -> String {
        let bytes = try readData(data, at: &offset, length: length)
        return String(data: bytes, encoding: .utf8)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func readData(_ data: Data, at offset: inout Int, length: Int) throws -> Data {
        try skip(data, at: &offset, count: 0)
        guard length >= 0, offset + length <= data.count else {
            throw MovesZipArchiveError.truncated
        }
        let slice = data.subdata(in: offset..<(offset + length))
        offset += length
        return slice
    }

    private static func skip(_ data: Data, at offset: inout Int, count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw MovesZipArchiveError.truncated
        }
        offset += count
    }
}
