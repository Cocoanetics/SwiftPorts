import Foundation

extension GitClient {

    /// The URL to authorize for a clone source (issue #122).
    ///
    /// git's scp-like remotes — `git@github.com:owner/repo.git`, or an
    /// `ssh_config` alias as in `myhost:repo.git` — aren't URLs.
    /// `URL(string:)` parses them with no host at all (or the alias as a
    /// bogus scheme), which a host-based sandbox gate can only reject
    /// ("non-file URL has no host to authorize"). Rewrite them to the
    /// equivalent `ssh://[user@]host/path` using git's own rule
    /// (`connect.c`): no `://`, and a colon before any slash. Anything
    /// else — real URLs, file URLs, local paths — passes through as is.
    /// Only the authorization sees the rewrite; libgit2 still gets the
    /// remote exactly as written.
    static func authorizationURL(forRemote url: URL) -> URL {
        guard !url.isFileURL, url.host == nil else { return url }
        let remote = url.absoluteString
        guard !remote.contains("://"),
              let colon = remote.firstIndex(of: ":"),
              !remote[..<colon].contains("/")
        else { return url }
        let userAndHost = remote[..<colon]
        #if os(Windows)
        // `C:/repo` is a drive letter, not a host (git's `has_dos_drive_prefix`).
        if userAndHost.count == 1, userAndHost.first?.isLetter == true { return url }
        #endif
        let path = remote[remote.index(after: colon)...]
        let separator = path.hasPrefix("/") ? "" : "/"
        return URL(string: "ssh://\(userAndHost)\(separator)\(path)") ?? url
    }
}
