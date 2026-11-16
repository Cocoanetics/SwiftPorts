import Foundation
import ShellKit
import SwiftGit

// `--verify-signatures` for `git merge` and `git pull`, after git's
// `builtin/merge.c`, `builtin/pull.c` and `commit.c`
// (`verify_merge_signature`): each commit to be merged is checked before
// anything changes, and the first one that isn't signed well stops it.
extension Merge {

    /// Whether to verify: the last of `--verify-signatures` /
    /// `--no-verify-signatures` (`flag`), else `merge.verifySignatures`.
    static func verifiesSignatures(_ flag: Bool?, client: SwiftGit.GitClient) async throws -> Bool {
        if let flag { return flag }
        return try await client.configBool("merge.verifySignatures") ?? false
    }

    /// git's `check_trust_level`: on, unless `gpg.minTrustLevel` is set
    /// at all, when the check's own minimum trust decides alone.
    static func checksTrust(client: SwiftGit.GitClient) async throws -> Bool {
        try await !client.configList().contains { $0.name.lowercased() == "gpg.mintrustlevel" }
    }

    /// Verify each of `commits` (an annotated tag by the commit it names)
    /// as git's `verify_merge_signature` does, in order: a good signature
    /// is said unless `quiet`, anything else stops with git's `fatal:`.
    static func verifyMergeSignatures(
        of commits: [String], quiet: Bool, client: SwiftGit.GitClient
    ) async throws {
        guard !commits.isEmpty else { return }
        let checkTrust = try await checksTrust(client: client)
        for commit in commits {
            let oid = (try? await client.resolveOID(commit + "^{commit}")) ?? commit
            switch try await client.mergeSignatureVerdict(oid, checkTrust: checkTrust) {
            case .good(let abbreviation, let signer):
                if !quiet { Shell.print("Commit \(abbreviation) has a good GPG signature by \(signer ?? "(null)")") }
            case .untrusted(let abbreviation, let signer):
                throw CLIError.stderr("fatal: Commit \(abbreviation) has an untrusted GPG signature, "
                    + "allegedly by \(signer ?? "(null)").", exitCode: 128)
            case .bad(let abbreviation, let signer):
                throw CLIError.stderr("fatal: Commit \(abbreviation) has a bad GPG signature "
                    + "allegedly by \(signer ?? "(null)").", exitCode: 128)
            case .unsigned(let abbreviation):
                throw CLIError.stderr("fatal: Commit \(abbreviation) does not have a GPG signature.", exitCode: 128)
            }
        }
    }
}

extension Pull {

    /// A rebase takes no `--verify-signatures`: git says so when its
    /// command line asks for it, and rebases.
    static func warnVerifySignaturesIgnored(_ flag: Bool?) {
        guard flag == true else { return }
        Shell.current.stderr.write("warning: ignoring --verify-signatures for rebase\n")
    }

    /// Verify what a pull merges, as git's pull does: into an unborn
    /// branch, the fetched commit, when the command line says either
    /// `--verify-signatures` or `--no-verify-signatures` (git passes the
    /// option on as given) and only then; otherwise as `git merge
    /// --[no-]verify-signatures FETCH_HEAD` verifies the heads that are
    /// left once reduced with HEAD.
    static func verifyPulledSignatures(
        _ heads: [SwiftGit.GitClient.FetchHeadEntry], current: String?, flag: Bool?, quiet: Bool,
        client: SwiftGit.GitClient
    ) async throws {
        guard current != nil else {
            if flag != nil, let head = heads.first {
                try await Merge.verifyMergeSignatures(of: [head.oid], quiet: quiet, client: client)
            }
            return
        }
        guard try await Merge.verifiesSignatures(flag, client: client) else { return }
        let reduced = try await client.mergeHeads(reducing: heads.map(\.oid))
        try await Merge.verifyMergeSignatures(of: reduced.heads, quiet: quiet, client: client)
    }
}
