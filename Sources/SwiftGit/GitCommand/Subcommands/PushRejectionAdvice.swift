import SwiftGit

/// git's verdict on a push it refused in part, `failed to push some refs
/// to '<url>'`, and the advice git gives for the first kind of refusal it
/// checks for (builtin/push.c).
enum PushRejectionAdvice {
    /// Which of git's push hints are on: all of them unless `GIT_ADVICE`
    /// is false, `advice.pushUpdateRejected` (or its old name
    /// `advice.pushNonFastForward`) is off, or the hint's own switch is.
    struct Switches {
        /// The `advice.*` keys that govern push hints.
        static let keys = [
            "pushUpdateRejected", "pushNonFastForward", "pushNonFFCurrent",
            "pushNonFFMatching", "pushAlreadyExists", "pushFetchFirst", "pushNeedsForce"
        ]
        var global = true
        /// Keys configured false, lowercased as git compares them.
        var off: Set<String> = []

        func enabled(_ key: String) -> Bool {
            global && ![key, "pushUpdateRejected", "pushNonFastForward"]
                .contains { off.contains($0.lowercased()) }
        }
    }

    /// The error for `rejected`. With `quiet`, it leads with the push's
    /// summary, which git shows for a failed push even then.
    static func error(
        for rejected: PushRejectedError, currentBranch: String?, quiet: Bool,
        switches: Switches = Switches()
    ) -> CLIError {
        var lines = quiet
            ? rejected.summary.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().map(String.init)
            : []
        lines.append("error: failed to push some refs to '\(rejected.url)'")
        let (key, hint) = advice(for: rejected.rejections, currentBranch: currentBranch)
        if let key, switches.enabled(key) {
            lines += hint.map { "hint: \($0)" }
        }
        return CLIError.stderr(lines, exitCode: 1)
    }

    /// The advice for the first kind of refusal git checks for, and the
    /// `advice.*` key that switches it off.
    private static func advice(
        for rejections: [PushRejectedError.Rejection], currentBranch: String?
    ) -> (key: String?, hint: [String]) {
        func any(_ reason: PushRejectedError.Reason) -> Bool {
            rejections.contains { $0.reason == reason }
        }
        let head = currentBranch.map { "refs/heads/\($0)" }
        if rejections.contains(where: { $0.reason == .nonFastForward && $0.remoteRef == head }) {
            return ("pushNonFFCurrent", [
                "Updates were rejected because the tip of your current branch is behind",
                "its remote counterpart. If you want to integrate the remote changes,",
                "use 'git pull' before pushing again.",
                fastForwardsNote
            ])
        }
        if any(.nonFastForward) {
            return ("pushNonFFMatching", [
                "Updates were rejected because a pushed branch tip is behind its remote",
                "counterpart. If you want to integrate the remote changes, use 'git pull'",
                "before pushing again.",
                fastForwardsNote
            ])
        }
        if any(.alreadyExists) {
            return ("pushAlreadyExists", ["Updates were rejected because the tag already exists in the remote."])
        }
        if any(.fetchFirst) {
            return ("pushFetchFirst", [
                "Updates were rejected because the remote contains work that you do not",
                "have locally. This is usually caused by another repository pushing to",
                "the same ref. If you want to integrate the remote changes, use",
                "'git pull' before pushing again.",
                fastForwardsNote
            ])
        }
        if any(.needsForce) {
            return ("pushNeedsForce", [
                "You cannot update a remote ref that points at a non-commit object,",
                "or update a remote ref to make it point at a non-commit object,",
                "without using the '--force' option."
            ])
        }
        return (nil, [])
    }

    private static let fastForwardsNote =
        "See the 'Note about fast-forwards' in 'git push --help' for details."
}
