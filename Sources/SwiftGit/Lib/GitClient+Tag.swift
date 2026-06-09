import Foundation
import ForgeKit
import libgit2

/// One entry returned by ``GitClient/tagList(pattern:)``. Annotated
/// tags carry a `message` + `tagger`; lightweight tags don't.
public struct TagEntry: Sendable, Equatable {
    public let name: String
    public let isAnnotated: Bool
    /// First line of the tag's annotation message, or the tagged
    /// commit's subject for lightweight tags. Used by `git tag -n`.
    public let summary: String
    /// Full tag SHA (the annotation object) for annotated tags, or
    /// the SHA of the tagged commit for lightweight tags.
    public let sha: String
    /// SHA of the underlying commit (for both flavours).
    public let targetSHA: String
}

extension GitClient {

    /// List tags whose name matches `pattern` (a fnmatch glob, e.g.
    /// `v1*`); pass `nil` for all tags. Names sort alphabetically to
    /// match `git tag`'s default order.
    public func tagList(pattern: String? = nil) async throws -> [String] {
        try await withRepository { repo in
            var arr = git_strarray()
            if let pattern {
                try check(pattern.withCString { p in
                    git_tag_list_match(&arr, p, repo)
                })
            } else {
                try check(git_tag_list(&arr, repo))
            }
            defer { git_strarray_dispose(&arr) }
            var names: [String] = []
            names.reserveCapacity(arr.count)
            for i in 0..<arr.count {
                if let cstr = arr.strings?[i] {
                    names.append(String(cString: cstr))
                }
            }
            return names.sorted()
        }
    }

    /// Detailed listing — fetches the message + target sha for each
    /// tag so the CLI can format `git tag -n` style annotations.
    public func tagDetails(pattern: String? = nil) async throws -> [TagEntry] {
        let names = try await tagList(pattern: pattern)
        return try await withRepository { repo in
            var entries: [TagEntry] = []
            entries.reserveCapacity(names.count)
            for name in names {
                if let entry = try? lookupTagEntry(repo: repo, name: name) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    /// Create a lightweight tag pointing at `target` (default HEAD).
    /// Throws when a tag with the same name exists unless `force == true`.
    @discardableResult
    public func tagCreate(
        name: String, target: String = "HEAD", force: Bool = false
    ) async throws -> String {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, target))
            defer { git_object_free(obj) }
            var oid = git_oid()
            try check(git_tag_create_lightweight(
                &oid, repo, name, obj, force ? 1 : 0))
            return formatOID(&oid)
        }
    }

    /// Create an annotated tag (signed object in `.git/objects` with
    /// tagger + message). The `tagger` defaults to the committer-role
    /// signature resolved through env vars + config.
    @discardableResult
    public func tagCreateAnnotated(
        name: String, target: String = "HEAD",
        message: String, tagger: GitSignature? = nil,
        force: Bool = false
    ) async throws -> String {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, target))
            defer { git_object_free(obj) }

            // Tagger uses the committer-role env precedence chain so
            // CI replay (`GIT_COMMITTER_*`) works the same way as for
            // commits.
            let sig = try SignatureResolver.resolve(
                role: .committer, override: tagger, repo: repo)
            defer { git_signature_free(sig) }

            var oid = git_oid()
            try check(message.withCString { msg in
                git_tag_create(&oid, repo, name, obj, sig, msg, force ? 1 : 0)
            })
            return formatOID(&oid)
        }
    }

    /// Delete a tag. Returns the SHA of what the tag was pointing at,
    /// for the `Deleted tag '<name>' (was <sha7>)` summary line.
    @discardableResult
    public func tagDelete(name: String) async throws -> String {
        try await withRepository { repo in
            // Fetch the target SHA before deletion for the summary.
            let entry = try lookupTagEntry(repo: repo, name: name)
            try check(name.withCString { n in
                git_tag_delete(repo, n)
            })
            return entry.sha
        }
    }

    /// True when a tag with `name` already exists. Used by the CLI to
    /// emit real-git's `tag '<name>' already exists` error wording.
    public func tagExists(_ name: String) async throws -> Bool {
        try await withRepository { repo in
            var ref: OpaquePointer?
            let rc = git_reference_lookup(&ref, repo, "refs/tags/\(name)")
            if rc == 0 { git_reference_free(ref); return true }
            if rc == GIT_ENOTFOUND.rawValue { return false }
            try check(rc)
            return false
        }
    }

    private func lookupTagEntry(repo: OpaquePointer?, name: String) throws -> TagEntry {
        // Resolve the tag's ref → object. For annotated tags this is
        // a `git_tag` object; for lightweight tags it's the underlying
        // commit directly.
        var refObj: OpaquePointer?
        try check(git_revparse_single(&refObj, repo, "refs/tags/\(name)"))
        defer { git_object_free(refObj) }

        var refOID = git_object_id(refObj)?.pointee ?? git_oid()
        let sha = formatOID(&refOID)

        // Distinguish annotated from lightweight by looking up the OID
        // as a tag object — succeeds only for annotated tags.
        var tag: OpaquePointer?
        let tagRC = git_tag_lookup(&tag, repo, &refOID)
        if tagRC == 0 {
            defer { git_tag_free(tag) }
            let messagePtr = git_tag_message(tag)
            let message = messagePtr.map { String(cString: $0) } ?? ""
            let summary = message.split(separator: "\n").first.map(String.init)
                ?? "(no message)"
            // Target id is the underlying commit.
            var targetID = git_tag_target_id(tag)?.pointee ?? git_oid()
            return TagEntry(
                name: name, isAnnotated: true,
                summary: summary, sha: sha,
                targetSHA: formatOID(&targetID))
        }

        // Lightweight: refOID IS the commit. Pull its subject.
        var commit: OpaquePointer?
        var summary = ""
        if git_commit_lookup(&commit, repo, &refOID) == 0 {
            defer { git_commit_free(commit) }
            let msg = git_commit_message(commit).map { String(cString: $0) } ?? ""
            summary = msg.split(separator: "\n").first.map(String.init) ?? ""
        }
        return TagEntry(
            name: name, isAnnotated: false,
            summary: summary, sha: sha, targetSHA: sha)
    }
}
