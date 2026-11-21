import ForgeKit
import SwiftGit

/// Opt-in, process-wide registration. Hosts call once before git operations.
public enum GitLFSKit {
    public static func installFilter() throws {
        try GitFilters.register(name: "lfs", GitFilter(clean: stream, smudge: stream))
    }

    public static func uninstallFilter() throws {
        try GitFilters.unregister(name: "lfs")
    }

    static let stream: GitFilter.StreamFactory = { source, output in
        let context = try GitFilterOperationContext.capture()
        let enabled = try BlockingBridge.runBlocking {
            try await context.withSource(source) { git in
                try await isEnabled(git, direction: source.direction)
            }
        }
        guard enabled else { return nil }
        // Part 1 (#230) only establishes startup and callback plumbing.
        // Streaming clean and queue-backed smudge follow in #231.
        return LFSPassthroughStream(output: output)
    }

    static func isEnabled(_ git: SwiftGit.GitClient, direction: GitFilterDirection) async throws -> Bool {
        let enabled: Bool
        // convert.c's apply_filter gives process precedence, even when empty.
        if let process = try await git.configGet("filter.lfs.process") {
            enabled = !process.isEmpty
        } else {
            let key = direction == .clean ? "filter.lfs.clean" : "filter.lfs.smudge"
            enabled = try await git.configGet(key).map { !$0.isEmpty } ?? false
        }
        if !enabled, try await git.configBool("filter.lfs.required") == true {
            throw LFSFilterUnavailable()
        }
        return enabled
    }
}
