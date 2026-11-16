import Foundation
import CGitKit
import ShellKit

// The tags a merge commit carries in its `mergetag` headers, as `git log` /
// `git show --show-signature` shows them, after git's `log-tree.c`
// (`show_mergetag`, `show_one_mergetag`) and `tag.c` (`parse_tag_buffer`).
// Each tag is read from the commit itself, so none has to be in the object
// database; its signature goes through the verifier `verify-tag` uses.
extension GitClient {

    /// One `mergetag` header of a commit: what git says the tag is to
    /// the commit, and the check of its signature.
    public struct MergeTag: Sendable {
        /// `merged tag '<name>'`, `parent #<n>, tagged '<name>'`,
        /// `tag <name> names a non-parent <oid>` or `malformed mergetag`.
        public var description: String
        /// The check of the tag's signature; `nil` when it has none.
        public var signature: SignatureCheck?
    }

    /// The `mergetag` headers of commit `oid`, in order, each described
    /// and its signature checked as git's `show_one_mergetag` does.
    public func mergeTags(_ oid: String) async throws -> [MergeTag] {
        guard let commit = try await rawObject(oid) else { return [] }
        let (parents, values) = Self.mergetagHeaders([UInt8](commit))
        var tags: [MergeTag] = []
        for value in values {
            let description = Self.describeMergetag(value, parents: parents)
            let signed = Self.split(Data(value))
            let signature = signed.signature.isEmpty ? nil : try await checkSignature(signed)
            tags.append(MergeTag(description: description, signature: signature))
        }
        return tags
    }

    /// A commit's parents and its `mergetag` values, as git's
    /// `read_commit_extra_header_lines` gives them: the header's first
    /// line and its continuation lines, each without its one leading
    /// space and ending in a newline.
    static func mergetagHeaders(_ bytes: [UInt8]) -> (parents: [String], values: [[UInt8]]) {
        var parents: [String] = []
        var values: [[UInt8]] = []
        var inMergetag = false
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            let line = bytes[start..<end]
            start = end + 1
            if line.isEmpty { break }
            if line.first == 0x20 {
                if inMergetag { values[values.count - 1] += line.dropFirst() + [0x0A] }
                continue
            }
            inMergetag = line.starts(with: Array("mergetag ".utf8))
            if inMergetag {
                values.append(Array(line.dropFirst("mergetag ".utf8.count)) + [0x0A])
            } else if line.starts(with: Array("parent ".utf8)) {
                parents.append(String(decoding: line.dropFirst("parent ".utf8.count), as: UTF8.self))
            }
        }
        return (parents, values)
    }

    /// The first line git shows for one mergetag `value` of a commit with
    /// `parents`: `malformed mergetag` when `parse_tag_buffer` refuses it
    /// (an unknown type said on stderr, as git does), else what the tag
    /// names among the parents.
    private static func describeMergetag(_ value: [UInt8], parents: [String]) -> String {
        guard let tag = parseTag(value) else { return "malformed mergetag\n" }
        if parents.count == 2, tag.object == parents[1] { return "merged tag '\(tag.name)'\n" }
        guard let nth = parents.firstIndex(of: tag.object) else {
            return "tag \(tag.name) names a non-parent \(tag.object)\n"
        }
        return "parent #\(nth + 1), tagged '\(tag.name)'\n"
    }

    /// git's `parse_tag_buffer` of a tag's bytes: the object it names
    /// and its name; `nil` when it can't be parsed.
    private static func parseTag(_ value: [UInt8]) -> (object: String, name: String)? {
        let hexSize = Int(GIT_OID_SHA1_HEXSIZE)
        guard value.count >= hexSize + 24, value.starts(with: Array("object ".utf8)) else { return nil }
        var cursor = 7
        let hex = value[cursor..<cursor + hexSize]
        guard hex.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0 | 0x20) }),
              value[cursor + hexSize] == 0x0A else { return nil }
        let object = String(decoding: hex, as: UTF8.self).lowercased()
        cursor += hexSize + 1

        guard value[cursor...].starts(with: Array("type ".utf8)) else { return nil }
        cursor += 5
        guard let typeEnd = value[cursor...].firstIndex(of: 0x0A), typeEnd - cursor < 20 else { return nil }
        let type = String(decoding: value[cursor..<typeEnd], as: UTF8.self)
        cursor = typeEnd + 1
        guard ["blob", "tree", "commit", "tag"].contains(type) else {
            var id = git_oid()
            _ = value.withUnsafeBytes { git_odb_hash(&id, $0.baseAddress, $0.count, GIT_OBJECT_TAG) }
            let oid = String(cString: git_oid_tostr_s(&id))
            Shell.current.stderr.write("error: unknown tag type '\(type)' in \(oid)\n")
            return nil
        }

        guard cursor + 4 < value.count, value[cursor...].starts(with: Array("tag ".utf8)) else { return nil }
        cursor += 4
        guard let nameEnd = value[cursor...].firstIndex(of: 0x0A) else { return nil }
        return (object, String(decoding: value[cursor..<nameEnd], as: UTF8.self))
    }
}
