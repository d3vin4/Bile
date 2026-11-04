import Foundation
import Compression

/// Minimal ZIP reader/writer used by the Files tab (compress / extract).
///
/// * Reading: STORE (0) and DEFLATE (8) — deflate is Apple's `COMPRESSION_ZLIB`
///   which is raw DEFLATE (RFC 1951), exactly what ZIP stores. ZIP64 entries
///   are refused with a clear error.
/// * Writing: STORE only — correct and dependency-free; compression is a nice-
///   to-have that can be layered on later. CRC-32 is computed in Swift.
enum ZipArchive {

    // MARK: - CRC-32 (IEEE 802.3), table-based

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Reading

    struct Entry {
        var name: String
        var path: String           // full destination path decided by the caller
        var method: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var crc: UInt32
        var dataOffset: UInt64     // absolute offset of the entry payload
        var isDirectory: Bool
        var isSymlink: Bool
        var linkTarget: String?
    }

    static func entries(in zipPath: String) throws -> [Entry] {
        guard let file = FileHandle(forReadingAtPath: zipPath) else {
            throw err("Cannot open \(zipPath)")
        }
        defer { try? file.close() }
        let data = try file.readDataToEndOfFile()
        return try entries(data: data)
    }

    static func entries(data: Data) throws -> [Entry] {
        // Locate the End Of Central Directory record (scan the last 64 KB + 22).
        guard data.count > 22 else { throw err("Not a ZIP file") }
        var eocdOffset = -1
        let scanFloor = max(0, data.count - (0xFFFF + 22))
        var i = data.count - 22
        while i >= scanFloor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw err("Not a ZIP file (no central directory)") }

        let count = Int(readU16(data, eocdOffset + 10))
        var cdOffset = Int(readU32(data, eocdOffset + 16))

        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard cdOffset + 46 <= data.count,
                  readU32(data, cdOffset) == 0x02014B50 else {
                throw err("Corrupt central directory")
            }
            let method = readU16(data, cdOffset + 10)
            let crc = readU32(data, cdOffset + 16)
            let compSize = UInt64(readU32(data, cdOffset + 20))
            let uncompSize = UInt64(readU32(data, cdOffset + 24))
            let nameLen = Int(readU16(data, cdOffset + 28))
            let extraLen = Int(readU16(data, cdOffset + 30))
            let commentLen = Int(readU16(data, cdOffset + 32))
            let extAttrs = readU32(data, cdOffset + 38)
            let localOffset = Int(readU32(data, cdOffset + 42))

            let nameStart = cdOffset + 46
            guard nameStart + nameLen <= data.count else { throw err("Corrupt entry name") }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)),
                              encoding: .utf8) ?? ""

            // ZIP64 marker → refuse clearly instead of extracting garbage.
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw err("ZIP64 archives are not supported: \(name)")
            }

            // Walk the local header to find where the payload really starts
            // (name/extra lengths may differ between central + local records).
            guard localOffset + 30 <= data.count,
                  readU32(data, localOffset) == 0x04034B50 else {
                throw err("Corrupt local header for \(name)")
            }
            let lNameLen = Int(readU16(data, localOffset + 26))
            let lExtraLen = Int(readU16(data, localOffset + 28))
            let dataOffset = UInt64(localOffset + 30 + lNameLen + lExtraLen)

            // Unix mode lives in the high 16 bits of the external attributes.
            let unixMode = Int((extAttrs >> 16) & 0xFFFF)
            let isDir = name.hasSuffix("/") || (unixMode & Int(S_IFMT)) == Int(S_IFDIR)
            let isSymlink = (unixMode & Int(S_IFMT)) == Int(S_IFLNK)

            var linkTarget: String? = nil
            if isSymlink {
                let raw = data.subdata(
                    in: Int(dataOffset)..<Int(dataOffset) + Int(compSize)
                )
                linkTarget = String(data: raw, encoding: .utf8)
            }

            out.append(Entry(
                name: name,
                path: name,
                method: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                crc: crc,
                dataOffset: dataOffset,
                isDirectory: isDir,
                isSymlink: isSymlink,
                linkTarget: linkTarget
            ))
            cdOffset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// Extracts one entry's payload (already located by `entries(data:)`).
    static func extractEntry(_ entry: Entry, from data: Data) throws -> Data {
        let payload = data.subdata(
            in: Int(entry.dataOffset)..<Int(entry.dataOffset + entry.compressedSize)
        )
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expected: Int(entry.uncompressedSize))
        default:
            throw err("Unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    /// Raw DEFLATE via Apple's Compression framework (`COMPRESSION_ZLIB` is raw
    /// RFC 1951 — exactly the format ZIP uses for method 8).
    static func inflate(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var dst = Data(count: expected)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            input.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, expected,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expected else {
            throw err("Inflate failed (\(written) of \(expected) bytes)")
        }
        return dst
    }

    /// Raw DEFLATE for writing method-8 entries. Returns nil when the payload
    /// does not compress (caller falls back to STORE).
    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var dst = Data(count: input.count)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            input.withUnsafeBytes { srcPtr -> Int in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    // MARK: - Writing

    struct Input {
        var name: String       // archive-relative name, "/" separated
        var isDir: Bool
        var data: Data
        var linkTarget: String?
    }

    /// Builds a complete archive from the given inputs (STORE method, or
    /// DEFLATE when the payload actually shrinks). Symlinks are stored as
    /// links, never followed.
    static func build(_ inputs: [Input]) throws -> Data {
        var out = Data()
        var central: Data = Data()
        var entriesCount: UInt16 = 0

        func writeFileEntry(_ input: Input) throws {
            let nameBytes = Data(input.name.utf8)
            let method: UInt16
            let payload: Data
            if input.isDir {
                method = 0
                payload = Data()
            } else if let linkTarget = input.linkTarget {
                method = 0
                payload = Data(linkTarget.utf8)
            } else if input.data.isEmpty {
                method = 0
                payload = Data()
            } else if let deflated = deflate(input.data), deflated.count < input.data.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = input.data
            }

            let crc = crc32(input.isDir ? Data() : (input.linkTarget != nil ? payload : input.data))
            let offset = UInt32(truncatingIfNeeded: out.count)
            let mode: UInt16 = input.isDir ? 0o40755 : (input.linkTarget != nil ? 0o120777 : 0o100644)

            // Local file header
            out.appendLE(UInt32(0x04034B50))
            out.appendLE(UInt16(20))            // version needed
            out.appendLE(UInt16(0x0800))        // UTF-8 names
            out.appendLE(method)
            out.appendLE(UInt16(0))             // mod time
            out.appendLE(UInt16(0))             // mod date (epoch is fine here)
            out.appendLE(crc)
            out.appendLE(UInt32(payload.count))
            out.appendLE(UInt32(input.isDir ? 0 : input.data.count))
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))             // extra len
            out.append(nameBytes)
            out.append(payload)

            // Central directory record
            central.appendLE(UInt32(0x02014B50))
            central.appendLE(UInt16(20))        // made by
            central.appendLE(UInt16(20))        // needed
            central.appendLE(UInt16(0x0800))
            central.appendLE(method)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(input.isDir ? 0 : input.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))         // extra
            central.appendLE(UInt16(0))         // comment
            central.appendLE(UInt16(0))         // disk number
            central.appendLE(UInt16(0))         // internal attrs
            central.appendLE(UInt32(mode) << 16)// external attrs (unix mode << 16)
            central.appendLE(offset)
            central.append(nameBytes)
            entriesCount += 1
        }

        for input in inputs {
            try writeFileEntry(input)
        }

        let cdOffset = UInt32(truncatingIfNeeded: out.count)
        out.append(central)
        // End of central directory
        out.appendLE(UInt32(0x06054B50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(entriesCount)
        out.appendLE(entriesCount)
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(cdOffset))
        out.appendLE(UInt16(0)) // comment len
        return out
    }

    // MARK: - Small helpers

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "ZipArchive", code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func readU16(_ d: Data, _ offset: Int) -> UInt16 {
        let b = d.subdata(in: offset..<(offset + 2))
        return b.withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    private static func readU32(_ d: Data, _ offset: Int) -> UInt32 {
        let b = d.subdata(in: offset..<(offset + 4))
        return b.withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
