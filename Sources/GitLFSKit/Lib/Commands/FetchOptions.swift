import SwiftGit

/// The supported options of git-lfs 3.7.1 `commands/command_fetch.go`.
public struct FetchOptions: Sendable {
    public var all = false
    public var include: String?
    public var exclude: String?
    public var dryRun = false
    public var json = false

    public init() {}

    public func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        do {
            _ = try await LFSRepository.open(git)
            if let remote = arguments.first { try await client.finder.validateRemote(remote) }
            var refs: [String] = []
            for name in arguments.dropFirst() {
                refs.append(try await client.commandRef(name, git: git))
            }
            if refs.isEmpty && !all { refs = [try await client.commandRef("HEAD", git: git)] }
            return try await client.fetch(
                refs: refs, remote: arguments.first ?? "", include: include, exclude: exclude,
                all: all, dryRun: dryRun, json: json, terminal: terminal, git: git)
        } catch let failure as LFSFailure {
            return failure.result
        }
    }
}
