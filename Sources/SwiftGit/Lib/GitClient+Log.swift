import Foundation
import CGitKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` log operation
// (`GitKit/Repository+Log.swift`). `revList` is not that walk: `log()`
// keeps `GIT_SORT_TIME | GIT_SORT_TOPOLOGICAL`.
extension GitClient {

    /// Walk commit history per `query`, newest first — `git log`.
    public func log(_ query: LogQuery = LogQuery()) async throws -> [LogEntry] {
        try await withRepository { try $0.log(query) }
    }

    /// Full commit ids in default `git rev-list` order.
    ///
    /// `starts` are the tips; an empty list walks `HEAD`. `excludes` hide
    /// those commits and their ancestors (`git rev-list <starts> --not
    /// <excludes>`). An unborn `HEAD` contributes nothing. Tags peel to
    /// the commit they name.
    ///
    /// The walk is libgit2's default (`GIT_SORT_NONE`): tips are seeded
    /// newest committer date first, and parents join a date-ordered queue
    /// as each commit is discovered. A parent committed later than one of
    /// its children can therefore appear before that child, once another
    /// child has already been listed. ``log(_:)`` does not use this order.
    public func revList(starts: [String], excludes: [String] = []) async throws -> [String] {
        try await withRepository { repository in
            guard let repo = Self.handle(of: repository) else {
                throw Libgit2Error(
                    code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                    message: "cannot reach GitKit's repository handle to walk revisions")
            }
            let tips = try Self.revListTips(starts.isEmpty ? ["HEAD"] : starts, repo: repo)
            guard !tips.isEmpty else { return [] }

            var walker: OpaquePointer?
            try Self.check(git_revwalk_new(&walker, repo))
            defer { git_revwalk_free(walker) }
            // Leave the walk on `GIT_SORT_NONE`. `GIT_SORT_TIME` re-sorts
            // the whole set by committer date and would list a newer
            // parent before every child.
            try Self.check(git_revwalk_sorting(walker, UInt32(GIT_SORT_NONE.rawValue)))
            // `git_revwalk_push` prepends, so the oldest tip goes in first
            // and the newest sits at the head, which is where `git rev-list`
            // starts.
            for tip in tips.reversed() {
                var oid = tip.oid
                try Self.check(git_revwalk_push(walker, &oid))
            }
            for spec in excludes {
                guard let hidden = try Self.revTip(spec, repo: repo) else { continue }
                var oid = hidden.oid
                try Self.check(git_revwalk_hide(walker, &oid))
            }

            var ids: [String] = []
            while true {
                try Task.checkCancellation()
                var oid = git_oid()
                let rc = git_revwalk_next(&oid, walker)
                if rc == GIT_ITEROVER.rawValue { break }
                try Self.check(rc)
                ids.append(String(cString: git_oid_tostr_s(&oid)))
            }
            return ids
        }
    }

    /// Tips in the order `git rev-list` seeds them: newest committer date
    /// first, the caller's order breaking a tie, duplicates dropped.
    private static func revListTips(_ specs: [String], repo: OpaquePointer?) throws -> [RevTip] {
        var seen: Set<String> = []
        var tips: [RevTip] = []
        for (ordinal, spec) in specs.enumerated() {
            guard var tip = try revTip(spec, repo: repo) else { continue }
            var oid = tip.oid
            let hex = String(cString: git_oid_tostr_s(&oid))
            guard seen.insert(hex).inserted else { continue }
            tip.ordinal = ordinal
            tips.append(tip)
        }
        tips.sort { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time > rhs.time }
            return lhs.ordinal < rhs.ordinal
        }
        return tips
    }

    /// The commit `spec` peels to, or nil when `spec` is an unborn `HEAD`.
    private static func revTip(_ spec: String, repo: OpaquePointer?) throws -> RevTip? {
        var object: OpaquePointer?
        let rc = git_revparse_single(&object, repo, spec)
        if rc != 0 {
            git_object_free(object)
            if spec == "HEAD", git_repository_head_unborn(repo) == 1 { return nil }
            try check(rc)
        }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_commit_free(commit) }
        guard let id = git_commit_id(commit) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_INVALID.rawValue),
                message: "could not read the id of \(spec)")
        }
        return RevTip(oid: id.pointee, time: git_commit_time(commit), ordinal: 0)
    }
}

/// One tip of a ``GitClient/revList(starts:excludes:)`` walk.
private struct RevTip {
    var oid: git_oid
    var time: Int64
    var ordinal: Int
}
