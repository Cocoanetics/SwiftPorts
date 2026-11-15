import SwiftGit

extension Merge {
    /// With no editor, git's prepare_to_commit uses cleanup_message's
    /// SPACE mode (stripspace without removing comment/signature lines).
    /// A conflict instead keeps the original message, before cleanup,
    /// followed by write_merge_state/suggest_conflicts' separators.
    static func merge(
        ref: String, fastForward: FastForwardMode, message: String?,
        client: SwiftGit.GitClient, sign: SignMode
    ) async throws -> MergeOutcome {
        let outcome = try await client.merge(
            ref: ref, fastForward: fastForward, message: message.map(SwiftGit.GitClient.stripspace),
            author: nil, sign: sign)
        if case .conflicts(let paths) = outcome {
            try await Pull.writeMergeMessage(message ?? "", conflicts: paths, client: client)
        }
        return outcome
    }
}
