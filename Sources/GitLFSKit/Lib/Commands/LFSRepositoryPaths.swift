import Foundation
import ShellKit
import SwiftGit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Android)
import Android
#endif

/// The path readouts of config.Configuration and fs.Filesystem.
struct LFSRepositoryPaths {
    let working: String
    let git: String
    let common: String
    let storage: String
    let media: String
    let temporary: String
    let references: [String]

    static func load(_ client: GitClient, configuration: LFSConfiguration) async -> LFSRepositoryPaths {
        let git = canonical(try? await client.gitDir())
        let common = canonical(try? await client.commonDir())
        let cwd = canonical(client.workingDirectory.path)
        let inGitDirectory = !git.isEmpty && (cwd == git || cwd.hasPrefix(git + "/"))
        let working = inGitDirectory ? "" : canonical(try? await client.toplevel())
        let storage: String
        let media: String
        let temporary: String
        let configured = configuration.get("lfs.storage") ?? ""
        if common.isEmpty && !(configured as NSString).isAbsolutePath {
            // fs.New joins an empty git dir with "lfs" outside a repository.
            storage = clean(configured.isEmpty ? "lfs" : configured)
            media = clean(storage + "/objects")
            temporary = clean(storage + "/tmp")
        } else {
            let store = LocalStore(gitStorageDirectory: URL(fileURLWithPath: common), storage: configured)
            storage = clean(store.storageDirectory.path)
            media = clean(store.objectsDirectory.path)
            temporary = clean(store.temporaryDirectory.path)
        }
        return LFSRepositoryPaths(
            working: working, git: git, common: common, storage: storage, media: media, temporary: temporary,
            references: await referenceDirectories(common: common, cwd: client.workingDirectory))
    }

    static func canonical(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        #if os(Windows)
        return clean(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        #else
        // Foundation intentionally shortens /private/var to /var on Darwin.
        // Git's physical directory and Go's EvalSymlinks retain /private.
        guard let physical = realpath(path, nil) else { return clean(path) }
        defer { free(physical) }
        return String(cString: physical)
        #endif
    }

    private static func clean(_ path: String) -> String {
        LFSEndpointDerivation.clean(path)
    }

    private static func referenceDirectories(common: String, cwd: URL) async -> [String] {
        #if os(Windows)
        let separator = ";"
        #else
        let separator = ":"
        #endif
        var candidates = Shell.env("GIT_ALTERNATE_OBJECT_DIRECTORIES")?.components(separatedBy: separator) ?? []
        let path = common.isEmpty ? "objects/info/alternates" : common + "/objects/info/alternates"
        let file = URL(fileURLWithPath: path, relativeTo: cwd)
        do {
            try await Shell.authorize(file)
            if FileManager.default.fileExists(atPath: file.path) {
                let text = try String(contentsOf: file, encoding: .utf8)
                candidates += text.components(separatedBy: "\n").filter {
                    let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !line.isEmpty && !line.hasPrefix("#")
                }
            }
        } catch { return [] }
        var references: [String] = []
        for candidate in candidates {
            var path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\"") {
                guard let end = path.dropFirst().lastIndex(of: "\""),
                      let unquoted = try? GoQuotedLiteral.unquote(String(path[...end])) else { continue }
                path = unquoted
            }
            // existsAlternate reports the sibling LFS objects directory, and
            // tests relative paths against cwd, even for the alternates file.
            let parent = (path as NSString).deletingLastPathComponent
            let storage = clean((parent.isEmpty ? "" : parent + "/") + "lfs/objects")
            let url = URL(fileURLWithPath: storage, relativeTo: cwd)
            do { try await Shell.authorize(url) } catch { continue }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                references.append(storage)
            }
        }
        return references
    }
}
