import Foundation
import SwiftGit

extension StatusOptions {
    func blobInfoFrom(_ entry: DiffIndexEntry, scanner: PointerScanner, root: URL) async throws -> BlobAnnotation {
        let oid = entry.oldOID.allSatisfy { $0 == "0" } ? entry.newOID : entry.oldOID
        return try await scanner.annotation(oid, name: entry.sourcePath, repositoryRoot: root)
    }

    func formatBlobInfo(_ entry: DiffIndexEntry, scanner: PointerScanner, root: URL) async throws -> String {
        let from = try await blobInfoFrom(entry, scanner: scanner, root: root)
        if entry.status == "A" { return Self.renderAnnotation(from) }
        let name = entry.destinationPath.isEmpty ? entry.sourcePath : entry.destinationPath
        let to = try await scanner.annotation(entry.newOID, name: name, repositoryRoot: root)
        return Self.renderAnnotation(from) + " -> " + Self.renderAnnotation(to)
    }

    private static func renderAnnotation(_ annotation: BlobAnnotation) -> String {
        switch annotation {
        case .lfs(let oid): return "LFS: \(oid.prefix(7))"
        case .git(let oid): return "Git: \(oid.prefix(7))"
        case .file(let oid): return "File: \(oid.prefix(7))"
        case .missing: return "?: <missing>"
        case .deleted: return "File: deleted"
        }
    }
}
