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
        guard source.driver == "lfs" else { return nil }
        let operation = try GitFilterOperationContext.capture()
        let context = try BlockingBridge.runBlocking {
            try await operation.withSource(source) { git in
                try await LFSFilterContext.load(git, direction: source.direction,
                                                remotes: LFSFilterRemotes.forOperation(operation, source: source))
            }
        }
        guard let context else { return nil }
        switch source.direction {
        case .clean: return LFSCleanStream(context: context, output: output.write)
        case .smudge: return LFSSmudgeStream(context: context, path: source.path, output: output.write)
        }
    }

    static func isEnabled(_ git: SwiftGit.GitClient, direction: GitFilterDirection) async throws -> Bool {
        try await LFSFilterContext.command(git, direction: direction) != nil
    }
}
