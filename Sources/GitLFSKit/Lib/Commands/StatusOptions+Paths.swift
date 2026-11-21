import Foundation
import SwiftGit

extension StatusOptions {
    /// Upstream's non-NUL diff scanner retains Git's C-quoted names, including
    /// when `blobInfo` later joins a name onto the worktree root. Keep the raw
    /// paths for pointer comparison, then reproduce that spelling at the boundary.
    static func quotePaths(_ index: StatusIndex, quotePath: Bool) -> StatusIndex {
        func quoted(_ entry: DiffIndexEntry) -> DiffIndexEntry {
            DiffIndexEntry(
                oldMode: entry.oldMode, newMode: entry.newMode, oldOID: entry.oldOID, newOID: entry.newOID,
                status: entry.status, similarity: entry.similarity,
                sourcePath: diffPath(entry.sourcePath, quotePath: quotePath),
                destinationPath: diffPath(entry.destinationPath, quotePath: quotePath))
        }
        return StatusIndex(staged: index.staged.map(quoted), unstaged: index.unstaged.map(quoted))
    }

    /// Git `quote_c_style`: control bytes use C escapes or three octal digits;
    /// core.quotePath controls octal escaping of bytes above ASCII only.
    static func diffPath(_ path: String, quotePath: Bool) -> String {
        func needsQuote(_ byte: UInt8) -> Bool {
            byte < 0x20 || byte == 0x22 || byte == 0x5C || byte == 0x7F || (quotePath && byte >= 0x80)
        }
        let bytes = Array(path.utf8)
        guard bytes.contains(where: needsQuote) else { return path }
        let escapes: [UInt8: String] = [
            0x07: "\\a", 0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0B: "\\v",
            0x0C: "\\f", 0x0D: "\\r", 0x22: "\\\"", 0x5C: "\\\\"
        ]
        var output: [UInt8] = [0x22]
        for byte in bytes {
            if let escape = escapes[byte] {
                output += escape.utf8
            } else if needsQuote(byte) {
                output += String(format: "\\%03o", Int(byte)).utf8
            } else {
                output.append(byte)
            }
        }
        output.append(0x22)
        return String(decoding: output, as: UTF8.self)
    }
}
