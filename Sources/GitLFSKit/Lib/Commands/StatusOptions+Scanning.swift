import Foundation
import ShellKit
import SwiftGit

extension StatusOptions {
    /// Upstream's `git update-index --refresh` runs the clean filter, so a
    /// smudged file whose bytes are the indexed pointer's target is clean
    /// relative to the index. No filter runs here: such a work-tree side is
    /// given the stage-zero index blob instead, and the record is dropped
    /// once it matches `ref` as well. Anything else is kept as diffed.
    func comparePointers(
        _ uncached: [DiffIndexEntry], cached: [DiffIndexEntry], client: GitClient, repositoryRoot: URL
    ) async throws -> [DiffIndexEntry] {
        guard uncached.contains(where: Self.isContentChange) else { return uncached }
        // Conflicted paths have no stage-zero entry and are never compared.
        var index: [[UInt8]: IndexedEntry] = [:]
        for entry in try await client.indexedEntries() where entry.stage == 0 {
            index[Array(entry.path.utf8)] = entry
        }
        let scanner = PointerScanner(client: client)
        var compared: [(entry: DiffIndexEntry, corrected: Bool)] = []
        compared.reserveCapacity(uncached.count)
        for entry in uncached {
            guard Self.isContentChange(entry),
                  let indexed = index[Array(entry.destinationPath.utf8)],
                  indexed.mode == entry.newMode,
                  let pointer = try await scanner.readPointer(indexed.oid),
                  try await Self.worktree(entry.destinationPath, root: repositoryRoot, matches: pointer)
            else {
                compared.append((entry, false))
                continue
            }
            if entry.status == "M" && entry.oldOID == indexed.oid && entry.oldMode == indexed.mode {
                continue
            }
            compared.append((DiffIndexEntry(
                oldMode: entry.oldMode, newMode: entry.newMode,
                oldOID: entry.oldOID, newOID: indexed.oid,
                status: entry.status, similarity: entry.similarity,
                sourcePath: entry.sourcePath, destinationPath: entry.destinationPath), true))
        }
        return Self.pairRenames(compared, cached: cached)
    }

    /// Rename detection ran before the correction. A corrected addition now
    /// has its index blob, as the cached diff does, so the cached diff's
    /// rename of that blob (git's 50% similarity pass) pairs it with the
    /// deletion of the same source. Otherwise git's exact pass pairs it with
    /// a deletion of the same blob. Either is listed at the addition.
    private static func pairRenames(
        _ compared: [(entry: DiffIndexEntry, corrected: Bool)], cached: [DiffIndexEntry]
    ) -> [DiffIndexEntry] {
        var paired = Set<Int>()
        var renamed: [Int: DiffIndexEntry] = [:]
        for (position, item) in compared.enumerated() where item.corrected && item.entry.status == "A" {
            let added = item.entry
            let rename = cached.first {
                $0.status == "R" && $0.newOID == added.newOID
                    && Array($0.destinationPath.utf8) == Array(added.destinationPath.utf8)
            }
            let deletion: (DiffIndexEntry) -> Bool = { deleted in
                guard let rename else { return deleted.oldOID == added.newOID }
                return deleted.oldOID == rename.oldOID
                    && Array(deleted.sourcePath.utf8) == Array(rename.sourcePath.utf8)
            }
            guard let source = compared.indices.first(where: {
                !paired.contains($0) && compared[$0].entry.status == "D" && deletion(compared[$0].entry)
            }) else { continue }
            paired.insert(source)
            let deleted = compared[source].entry
            renamed[position] = DiffIndexEntry(
                oldMode: deleted.oldMode, newMode: added.newMode,
                oldOID: deleted.oldOID, newOID: added.newOID,
                status: "R", similarity: rename?.similarity ?? 100,
                sourcePath: deleted.sourcePath, destinationPath: added.destinationPath)
        }
        return compared.indices.compactMap { position in
            paired.contains(position) ? nil : renamed[position] ?? compared[position].entry
        }
    }

    /// A regular work-tree file git has not hashed (an all-zero new id).
    private static func isContentChange(_ entry: DiffIndexEntry) -> Bool {
        ["M", "A", "R"].contains(entry.status)
            && [0o100644, 0o100755].contains(entry.newMode)
            && entry.newOID.allSatisfy { $0 == "0" }
    }

    /// Streams the whole regular file at `name`, relative to the repository root.
    private static func worktree(_ name: String, root: URL, matches pointer: Pointer) async throws -> Bool {
        let path = root.appendingPathComponent(name)
        try await Shell.authorize(path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch CocoaError.fileReadNoSuchFile {
            return false
        } catch CocoaError.fileNoSuchFile {
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == pointer.size else { return false }
        return try LocalStore.sha256(of: path).0 == pointer.oid
    }
}
