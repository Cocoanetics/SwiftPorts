import Foundation
import CGitKit
import ShellKit
import SwiftGit

extension PointerScanner {
    /// Resolve one status side. Worktree names are relative to the repository root.
    func annotation(_ oid: String, name: String, repositoryRoot: URL) async throws -> BlobAnnotation {
        if [40, 64].contains(oid.utf8.count) && oid.allSatisfy({ $0 == "0" }) {
            let path = repositoryRoot.appendingPathComponent(name)
            try await Shell.authorize(path)
            do {
                // Follow links as os.Open/Stat do, after authorizing the original path.
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: path.resolvingSymlinksInPath().path)
                if attributes[.type] as? FileAttributeType == .typeDirectory { return .deleted }
                return .file(try LocalStore.sha256(of: path).0)
            } catch CocoaError.fileReadNoSuchFile {
                return .deleted
            } catch CocoaError.fileNoSuchFile {
                return .deleted
            }
        }
        do {
            let blob = try await scanBlob(oid)
            return blob.pointer == nil ? .git(blob.contentsSHA256) : .lfs(blob.contentsSHA256)
        } catch let error as Libgit2Error
            where error.code == GIT_ENOTFOUND.rawValue && error.klass == Int32(GIT_ERROR_ODB.rawValue) {
            return .missing
        }
    }
}
