import Foundation
import CGitKit
import ShellKit
import SwiftGit

extension StatusOptions {
    /// Upstream's `git update-index --refresh` runs the clean filter, so a
    /// smudged file whose bytes are the indexed pointer's target is clean
    /// relative to the index. No filter runs here: such a work-tree side is
    /// given the stage-zero index blob instead, and the record is dropped
    /// once it matches `ref` as well. Anything else is kept as diffed.
    func comparePointers(
        _ uncached: [DiffIndexEntry], client: GitClient, repositoryRoot: URL
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
        return try await Self.pairRenames(compared, client: client)
    }

    /// Rename detection ran before the correction, and libgit2 cannot
    /// score a work-tree side it would have to clean. Each corrected addition
    /// now has its index blob, so it is scored against the unpaired deletions
    /// as `git_diff_find_similar` does at its 50% default: the first identical
    /// blob, else the best signature match. The rename is listed at the addition.
    private static func pairRenames(
        _ compared: [(entry: DiffIndexEntry, corrected: Bool)], client: GitClient
    ) async throws -> [DiffIndexEntry] {
        var paired = Set<Int>()
        var renamed: [Int: DiffIndexEntry] = [:]
        for (position, item) in compared.enumerated() where item.corrected && item.entry.status == "A" {
            let added = item.entry
            var best: (source: Int, score: Int)?
            for source in compared.indices where !paired.contains(source) && compared[source].entry.status == "D" {
                let score = try await similarity(compared[source].entry, added, client: client)
                if score >= 50 && score > (best?.score ?? -1) { best = (source, score) }
                if score == 100 { break }
            }
            guard let best else { continue }
            paired.insert(best.source)
            let deleted = compared[best.source].entry
            renamed[position] = DiffIndexEntry(
                oldMode: deleted.oldMode, newMode: added.newMode,
                oldOID: deleted.oldOID, newOID: added.newOID,
                status: "R", similarity: best.score,
                sourcePath: deleted.sourcePath, destinationPath: added.destinationPath)
        }
        return compared.indices.compactMap { position in
            paired.contains(position) ? nil : renamed[position] ?? compared[position].entry
        }
    }

    /// libgit2's `similarity_measure` for two blobs: blob modes only, 100 for
    /// one id, nothing for sizes over 8x apart, else the hashsig score with
    /// smart whitespace and small files allowed. -1 is "not comparable".
    private static func similarity(
        _ deleted: DiffIndexEntry, _ added: DiffIndexEntry, client: GitClient
    ) async throws -> Int {
        guard [0o100644, 0o100755].contains(deleted.oldMode) else { return -1 }
        if deleted.oldOID == added.newOID { return 100 }
        let old = try await client.catFileBlob(deleted.oldOID)
        let new = try await client.catFileBlob(added.newOID)
        if old.count > 127 && new.count > 127 && (old.count > new.count << 3 || new.count > old.count << 3) {
            return -1
        }
        let options = git_hashsig_option_t(
            GIT_HASHSIG_SMART_WHITESPACE.rawValue | GIT_HASHSIG_ALLOW_SMALL_FILES.rawValue)
        func signature(_ data: Data) throws -> OpaquePointer? {
            var signature: OpaquePointer?
            let code = data.withUnsafeBytes {
                git_hashsig_create(&signature, $0.baseAddress?.assumingMemoryBound(to: CChar.self),
                                   $0.count, options)
            }
            guard code >= 0 else { throw hashsigError(code) }
            return signature
        }
        func hashsigError(_ code: Int32) -> Libgit2Error {
            let last = git_error_last()?.pointee
            return Libgit2Error(code: code, klass: last?.klass ?? -1,
                                message: last?.message.map { String(cString: $0) } ?? "hashsig failed")
        }
        let oldSignature = try signature(old)
        defer { git_hashsig_free(oldSignature) }
        let newSignature = try signature(new)
        defer { git_hashsig_free(newSignature) }
        let score = git_hashsig_compare(oldSignature, newSignature)
        guard score >= 0 else { throw hashsigError(score) }
        return Int(score)
    }

    /// A regular work-tree side, including a candidate rename detection has
    /// already hashed without running a clean filter or storing its blob.
    private static func isContentChange(_ entry: DiffIndexEntry) -> Bool {
        ["M", "A", "R", "T"].contains(entry.status)
            && [0o100644, 0o100755].contains(entry.newMode)
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
