import Foundation
import SwiftGit

/// Options of git-lfs 3.7.1 `commands/command_ls_files.go`.
public struct LsFilesOptions: Sendable {
    public var long = false
    public var size = false
    public var nameOnly = false
    public var debug = false
    public var all = false
    public var deleted = false
    public var json = false
    public var include = ""
    public var exclude = ""

    public init() {}

    public func lsFiles(_ refs: [String], client: SwiftGit.GitClient) async throws -> LFSCommandResult {
        var result = LFSCommandResult()
        do {
            let repo = try await LFSRepository.open(client)
            if all && !refs.isEmpty { throw LFSFailure("Cannot use --all with explicit reference") }
            if refs.first == "--all" { throw LFSFailure("Did you mean `git lfs ls-files --all --` ?") }
            if deleted && refs.count > 1 { throw LFSFailure("Cannot use --deleted with reference range") }

            let scanner = GitScanner(client: client, filter: FilepathFilter(
                include: Self.cleanPaths(include), exclude: Self.cleanPaths(exclude)))
            let store = LocalStore(gitStorageDirectory: repo.commonDirectory,
                                   storage: try await client.configGet("lfs.storage"))
            var seen = Set<[UInt8]>()
            var items: [LsFilesObject] = []
            // No positional arguments: upstream scans the index before --all,
            // --deleted, or the HEAD tree. An explicit ref skips the index.
            if refs.isEmpty {
                do {
                    // The shared scanner also returns HEAD's tree. Keep just
                    // the changed destinations for this upstream ScanIndex pass.
                    let staged = try await scanner.scanIndex().filter { !$0.status.isEmpty }
                    try await render(staged, repo: repo, store: store,
                                     deduplicate: !all && refs.count < 2,
                                     seen: &seen, items: &items, output: &result.stdout)
                } catch {
                    throw LFSFailure("Could not scan for Git LFS index: \(error.localizedDescription)")
                }
            }
            do {
                let pointers: [WrappedPointer]
                if all {
                    pointers = try await scanner.scanAll()
                } else if deleted {
                    pointers = try await scanner.scanRefs(include: [refs.first ?? "HEAD"])
                } else if refs.count > 1 {
                    pointers = try await scanner.scanRefs(include: [refs[1]], exclude: [refs[0]])
                } else if refs.isEmpty, try await !client.canResolveRef("HEAD") {
                    pointers = [] // The unborn HEAD's empty tree.
                } else {
                    pointers = try await scanner.scanTree(refs.first ?? "HEAD")
                }
                try await render(pointers, repo: repo, store: store,
                                 deduplicate: !all && refs.count < 2,
                                 seen: &seen, items: &items, output: &result.stdout)
            } catch {
                let kind = all ? "history" : "tree"
                let ref = (!all && !deleted && refs.count < 2) ? (refs.first ?? "HEAD") : nil
                throw LFSFailure(Self.scanFailure(kind, error: error, ref: ref))
            }
            if json {
                let files = items.isEmpty ? "null" : "[\n" + items.map(\.json).joined(separator: ",\n") + "\n ]"
                result.stdout += "{\n \"files\": \(files)\n}\n"
            }
        } catch let error as LFSFailure {
            result.stderr += error.result.stderr
            result.stdout += error.result.stdout
            result.status = error.result.status
        } catch {
            result.fail(error.localizedDescription)
        }
        return result
    }

    /// git-lfs wraps `git ls-tree`'s stderr. That text already ends in a newline,
    /// and `commands.Error` adds another, so the message keeps one trailing newline
    /// for ``LFSFailure`` to finish.
    private static func scanFailure(_ kind: String, error: Error, ref: String?) -> String {
        let detail: String
        if let ref, isUnresolvedRevision(error) {
            detail = "error in `git ls-tree`: exit status 128 fatal: Not a valid object name \(ref)\n"
        } else {
            detail = error.localizedDescription
        }
        return "Could not scan for Git LFS \(kind): \(detail)"
    }

    private static func isUnresolvedRevision(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("not found") || text.contains("revspec") || text.contains("failed to parse")
            || text.contains("invalid pattern") || text.contains("not valid")
    }

    /// `tools.CleanPaths`: trim whitespace, then a single trailing separator.
    private static func cleanPaths(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: ",").map {
            let part = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return part.hasSuffix("/") || part.hasSuffix("\\") ? String(part.dropLast()) : part
        }
    }
}
