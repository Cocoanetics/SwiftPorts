import Foundation

/// Go 1.23 `net/http.DetectContentType`, including signature order and the
/// 512-byte limit. Reference: golang/go, src/net/http/sniff.go (BSD-3-Clause).
enum HTTPContentType {
    static func detect(_ data: Data) -> String {
        let bytes = Array(data.prefix(512))
        let text = Array(bytes.drop(while: { [9, 10, 12, 13, 32].contains($0) }))
        for tag in ["<!DOCTYPE HTML", "<HTML", "<HEAD", "<SCRIPT", "<IFRAME", "<H1", "<DIV",
                    "<FONT", "<TABLE", "<A", "<STYLE", "<TITLE", "<B", "<BODY", "<BR", "<P", "<!--"] {
            let pattern = Array(tag.utf8)
            if text.count > pattern.count,
               zip(text, pattern).allSatisfy({ byte, expected in
                   ((65...90).contains(expected) ? byte & 0xDF : byte) == expected
               }), [32, 62].contains(text[pattern.count]) {
                return "text/html; charset=utf-8"
            }
        }
        if text.starts(with: Array("<?xml".utf8)) { return "text/xml; charset=utf-8" }
        for (pattern, type) in signatures where matches(bytes, pattern) { return type }
        if isMP4(bytes) { return "video/mp4" }
        for (pattern, type) in trailingSignatures where matches(bytes, pattern) { return type }
        if text.contains(where: { $0 <= 8 || $0 == 11 || (14...26).contains($0) || (28...31).contains($0) }) {
            return "application/octet-stream"
        }
        return "text/plain; charset=utf-8"
    }

    // `??` is Go's zero mask. All other bytes have an FF mask.
    private static func matches(_ bytes: [UInt8], _ signature: String) -> Bool {
        let pattern = signature.split(separator: " ")
        guard bytes.count >= pattern.count else { return false }
        return zip(bytes, pattern).allSatisfy { byte, expected in
            expected == "??" || UInt8(expected, radix: 16) == byte
        }
    }

    private static func isMP4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else { return false }
        let size = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size <= bytes.count, size % 4 == 0,
              bytes[4..<8].elementsEqual("ftyp".utf8) else { return false }
        for start in stride(from: 8, to: size, by: 4) where start != 12 {
            if bytes[start..<start + 3].elementsEqual("mp4".utf8) { return true }
        }
        return false
    }

    private static let signatures: [(String, String)] = [
        ("25 50 44 46 2D", "application/pdf"),
        ("25 21 50 53 2D 41 64 6F 62 65 2D", "application/postscript"),
        ("FE FF ?? ??", "text/plain; charset=utf-16be"),
        ("FF FE ?? ??", "text/plain; charset=utf-16le"),
        ("EF BB BF ??", "text/plain; charset=utf-8"),
        ("00 00 01 00", "image/x-icon"),
        ("00 00 02 00", "image/x-icon"),
        ("42 4D", "image/bmp"),
        ("47 49 46 38 37 61", "image/gif"),
        ("47 49 46 38 39 61", "image/gif"),
        ("52 49 46 46 ?? ?? ?? ?? 57 45 42 50 56 50", "image/webp"),
        ("89 50 4E 47 0D 0A 1A 0A", "image/png"),
        ("FF D8 FF", "image/jpeg"),
        ("46 4F 52 4D ?? ?? ?? ?? 41 49 46 46", "audio/aiff"),
        ("2E 73 6E 64", "audio/basic"),
        ("49 44 33", "audio/mpeg"),
        ("4F 67 67 53 00", "application/ogg"),
        ("4D 54 68 64 00 00 00 06", "audio/midi"),
        ("52 49 46 46 ?? ?? ?? ?? 41 56 49 20", "video/avi"),
        ("52 49 46 46 ?? ?? ?? ?? 57 41 56 45", "audio/wave")
    ]

    private static let trailingSignatures: [(String, String)] = [
        ("1A 45 DF A3", "video/webm"),
        (Array(repeating: "??", count: 34).joined(separator: " ") + " 4C 50", "application/vnd.ms-fontobject"),
        ("00 01 00 00", "font/ttf"),
        ("4F 54 54 4F", "font/otf"),
        ("74 74 63 66", "font/collection"),
        ("77 4F 46 46", "font/woff"),
        ("77 4F 46 32", "font/woff2"),
        ("1F 8B 08", "application/x-gzip"),
        ("50 4B 03 04", "application/zip"),
        ("52 61 72 21 1A 07 00", "application/x-rar-compressed"),
        ("52 61 72 21 1A 07 01 00", "application/x-rar-compressed"),
        ("00 61 73 6D", "application/wasm")
    ]
}
