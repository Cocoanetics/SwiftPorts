import Foundation
import libgit2

extension GitClient {

    /// Mirrors `git describe` — find the most recent tag reachable from
    /// `committish` (default HEAD) and append a suffix when the commit
    /// is past that tag.
    ///
    /// - Parameters:
    ///   - committish: Ref to start from. Default `HEAD`.
    ///   - tags: Match lightweight tags too (real git's `--tags`). When
    ///     `false`, only annotated tags are considered.
    ///   - abbrev: Number of hex chars in the SHA suffix. `0` suppresses
    ///     the suffix even when ahead of the tag.
    ///   - dirty: Append `-dirty` when the working tree differs from
    ///     HEAD. Real git's `--dirty` defaults to "-dirty"; the suffix
    ///     here is fixed to match.
    public func describe(
        committish: String = "HEAD",
        tags: Bool = false,
        abbrev: Int = 7,
        dirty: Bool = false
    ) async throws -> String {
        try await withRepository { repo in
            // Resolve `committish` → object so describe walks from it
            // rather than HEAD.
            var obj: OpaquePointer?
            try check(committish.withCString { name in
                git_revparse_single(&obj, repo, name)
            })
            defer { git_object_free(obj) }

            var opts = git_describe_options()
            try check(git_describe_options_init(&opts, UInt32(GIT_DESCRIBE_OPTIONS_VERSION)))
            opts.describe_strategy = tags
                ? UInt32(GIT_DESCRIBE_TAGS.rawValue)
                : UInt32(GIT_DESCRIBE_DEFAULT.rawValue)

            var result: OpaquePointer?
            try check(git_describe_commit(&result, obj, &opts))
            defer { git_describe_result_free(result) }

            var formatOpts = git_describe_format_options()
            try check(git_describe_format_options_init(
                &formatOpts, UInt32(GIT_DESCRIBE_FORMAT_OPTIONS_VERSION)))
            formatOpts.abbreviated_size = UInt32(max(0, abbrev))
            // libgit2 wants a non-NULL `dirty_suffix` to mark a dirty
            // tree — leave NULL when the caller didn't ask for it.
            var buf = git_buf()
            defer { git_buf_dispose(&buf) }
            if dirty {
                let suffix = "-dirty"
                try suffix.withCString { ptr in
                    formatOpts.dirty_suffix = ptr
                    try check(git_describe_format(&buf, result, &formatOpts))
                }
            } else {
                try check(git_describe_format(&buf, result, &formatOpts))
            }
            guard let cstr = buf.ptr else { return "" }
            return String(cString: cstr)
        }
    }
}
