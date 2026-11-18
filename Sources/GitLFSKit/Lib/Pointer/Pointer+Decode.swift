import Foundation
import ShellKit

// Decoding, as git-lfs's `DecodeFrom` / `decodeKV` / `decodeKVData` do it,
// byte for byte (`lfs/pointer.go`).
extension Pointer {

    /// The keys a pointer carries, in the order it must carry them.
    static let pointerKeys = ["version", "oid", "size"]

    /// Decodes the pointer at the start of `data` (`DecodePointer`). Only
    /// the first ``blobSizeCutoff`` bytes are looked at; no bytes at all is
    /// the empty pointer. Throws a ``PointerError`` worded as git-lfs's.
    public static func decode(_ data: Data) throws -> Pointer {
        let buffer = [UInt8](data.prefix(blobSizeCutoff))
        guard !buffer.isEmpty else { return .empty }
        var pointer = try decodeKV(trimSpace(buffer))
        pointer.canonical = Array(pointer.encoded.utf8) == buffer
        return pointer
    }

    /// Decodes the pointer file at `url` (`DecodePointerFromFile`): it must
    /// be a regular file under ``blobSizeCutoff`` bytes.
    public static func decode(fileAt url: URL) async throws -> Pointer {
        try await Shell.authorize(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PointerError.notARegularFile(url.path)
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size < blobSizeCutoff else { throw PointerError.fileSizeExceedsCutoff }
        return try decode(Data(contentsOf: url))
    }

    // MARK: Key/value lines

    private static func decodeKV(_ data: [UInt8]) throws -> Pointer {
        let (kvps, exts) = try decodeKVData(data)

        let version = kvps["version"] ?? ""
        guard !version.isEmpty else { throw PointerError.missingVersion }
        guard v1Aliases.contains(version) else { throw PointerError.invalidVersion(version) }

        guard let oidValue = kvps["oid"] else { throw PointerError.missingOID }
        let oid = try parseOID(oidValue)

        let sizeValue = kvps["size"] ?? ""
        guard let size = Int64(sizeValue), size >= 0 else { throw PointerError.invalidSize(sizeValue) }

        var extensions: [PointerExtension] = []
        for (key, value) in exts {
            extensions.append(try parseExtension(key: key, value: value))
        }
        var priorities = Set<Int>()
        for ext in extensions where !priorities.insert(ext.priority).inserted {
            throw PointerError.duplicatePriority(ext.priority)
        }
        extensions.sort { $0.priority < $1.priority }

        return Pointer(oid: oid, size: size, extensions: extensions)
    }

    /// The `version` / `oid` / `size` values, and the extension lines met
    /// along the way (a repeated extension key keeps its last value, as
    /// git-lfs's map does).
    private static func decodeKVData(_ data: [UInt8]) throws -> ([String: String], [(String, String)]) {
        guard ["git-media", "hawser", "git-lfs"].contains(where: { data.contains(subsequence: Array($0.utf8)) }) else {
            throw PointerError.invalidHeader
        }

        var kvps: [String: String] = [:]
        var exts: [(String, String)] = []
        var line = 0
        for bytes in scanLines(data) where !bytes.isEmpty {
            let text = String(decoding: bytes, as: UTF8.self)
            guard let space = bytes.firstIndex(of: 0x20) else {
                throw PointerError.errorReadingLine(line, text)
            }
            let key = String(decoding: bytes[..<space], as: UTF8.self)
            let value = String(decoding: bytes[(space + 1)...], as: UTF8.self)

            guard line < pointerKeys.count else { throw PointerError.extraLine(text) }

            let expected = pointerKeys[line]
            if key != expected {
                guard isExtensionKey(key) else {
                    throw PointerError.badPointerKey(expected: expected, actual: key)
                }
                if let index = exts.firstIndex(where: { $0.0 == key }) {
                    exts[index].1 = value
                } else {
                    exts.append((key, value))
                }
                continue
            }

            line += 1
            kvps[key] = value
        }
        return (kvps, exts)
    }

    private static func parseOID(_ value: String) throws -> String {
        guard let colon = value.firstIndex(of: ":") else { throw PointerError.invalidOIDValue(value) }
        let type = String(value[..<colon])
        guard type == oidType else { throw PointerError.invalidOIDType(type) }
        let oid = String(value[value.index(after: colon)...])
        guard oid.utf8.count == 64, oid.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw PointerError.invalidOID(oid)
        }
        return oid
    }

    private static func parseExtension(key: String, value: String) throws -> PointerExtension {
        let parts = key.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "ext" else { throw PointerError.invalidExtensionValue(value) }
        guard let priority = Int(parts[1]), priority >= 0 else { throw PointerError.invalidPriority(parts[1]) }
        return PointerExtension(name: parts[2], priority: priority, oid: try parseOID(value))
    }

    /// `\Aext-\d{1}-\w+`: a prefix match, so anything may follow the first
    /// word character.
    private static func isExtensionKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        func isWord(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
        }
        return bytes.count >= 7 && bytes[0..<4].elementsEqual("ext-".utf8)
            && (0x30...0x39).contains(bytes[4]) && bytes[5] == 0x2D && isWord(bytes[6])
    }

    // MARK: Go's byte helpers

    /// `bufio.ScanLines`: split at `\n`, dropping a `\r` before it.
    private static func scanLines(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if data.last == 0x0A { lines.removeLast() }
        return lines.map { $0.last == 0x0D ? $0.dropLast() : $0 }
    }

    /// `bytes.TrimSpace`: drops leading and trailing white space as
    /// `unicode.IsSpace` sees it.
    static func trimSpace(_ data: [UInt8]) -> [UInt8] {
        var start = 0, end = data.count
        while start < end, let width = spaceWidth(data, at: start) { start += width }
        while end > start {
            var lead = end - 1
            while lead > start, end - lead < 4, data[lead] & 0xC0 == 0x80 { lead -= 1 }
            guard let width = spaceWidth(data, at: lead), lead + width == end else { break }
            end = lead
        }
        return Array(data[start..<end])
    }

    /// The width of the space character starting at `index`, if one does.
    private static func spaceWidth(_ data: [UInt8], at index: Int) -> Int? {
        let byte = data[index]
        if byte < 0x80 {
            return [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].contains(byte) ? 1 : nil
        }
        let width = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
        guard index + width <= data.count,
              let scalar = String(bytes: data[index..<index + width], encoding: .utf8)?.unicodeScalars.first
        else { return nil }
        let spaces: Set<UInt32> = [0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        return spaces.contains(scalar.value) || (0x2000...0x200A).contains(scalar.value) ? width : nil
    }
}
