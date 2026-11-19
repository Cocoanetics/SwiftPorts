import Foundation
import ShellKit

/// git-lfs `lfs/hook.go`: the standard hooks and the historical scripts it upgrades.
public struct Hook: Sendable {
    public let type: String
    public let directory: URL

    public init(type: String, directory: URL) {
        self.type = type
        self.directory = directory
    }

    public static func loadHooks(directory: URL) -> [Hook] {
        ["pre-push", "post-checkout", "post-commit", "post-merge"].map { Hook(type: $0, directory: directory) }
    }

    public var path: URL { directory.appendingPathComponent(type) }

    public var contents: String {
        "#!/bin/sh\ncommand -v git-lfs >/dev/null 2>&1 || { printf >&2 \"\\n%s\\n\\n\" \""
            + missingMessage + "\"; exit 2; }\ngit lfs \(type) \"$@\""
    }

    private var missingMessage: String {
        "This repository is configured for Git LFS but 'git-lfs' was not found on your path. "
            + "If you no longer wish to use Git LFS, remove this hook by deleting the '\(type)' "
            + "file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks')."
    }

    public func install(force: Bool = false) async throws {
        try await Shell.authorize(directory)
        try await Shell.authorize(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists && !force {
            if try matchesCurrent() { return }
        }
        try (contents + "\n").write(to: path, atomically: false, encoding: .utf8)
        if !exists {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
    }

    public func uninstall() async throws {
        try await Shell.authorize(path)
        _ = try matchesCurrent()
        try FileManager.default.removeItem(at: path)
    }

    /// Returns whether the script is already current; throws for a foreign script.
    private func matchesCurrent() throws -> Bool {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "(?m)^[ \\t]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text == contents { return true }
        if text.isEmpty || upgradeables.contains(text) { return false }
        throw LFSFailure("Hook already exists: \(type)\n\n\t"
            + text.replacingOccurrences(of: "\n", with: "\n\t") + "\n")
    }

    private var upgradeables: [String] {
        let prefix = "#!/bin/sh\ncommand -v git-lfs >/dev/null 2>&1 || { echo >&2 \"\\n"
        var values = [
            prefix + missingMessage + "\\n\"; exit 2; }\ngit lfs \(type) \"$@\"",
            prefix + "This repository is configured for Git LFS but 'git-lfs' was not found on your path. "
                + "If you no longer wish to use Git LFS, remove this hook by deleting '.git/hooks/\(type)'."
                + "\\n\"; exit 2; }\ngit lfs \(type) \"$@\"",
            prefix + "This repository is configured for Git LFS but 'git-lfs' was not found on your path. "
                + "If you no longer wish to use Git LFS, remove this hook by deleting .git/hooks/\(type)."
                + "\\n\"; exit 2; }\ngit lfs \(type) \"$@\""
        ]
        if type == "pre-push" {
            values += ["#!/bin/sh\ngit lfs push --stdin $*", "#!/bin/sh\ngit lfs push --stdin \"$@\"",
                       "#!/bin/sh\ngit lfs pre-push \"$@\""]
            for code in [0, 2] {
                values.append(prefix + "This repository has been set up with Git LFS but Git LFS is not installed."
                    + "\\n\"; exit \(code); }\ngit lfs pre-push \"$@\"")
            }
        }
        return values
    }
}
