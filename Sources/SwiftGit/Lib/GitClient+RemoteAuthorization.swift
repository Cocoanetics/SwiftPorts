import Foundation

extension GitClient {

    /// The URL to authorize for a clone source (issue #122).
    ///
    /// git's scp-like remotes — `git@github.com:owner/repo.git`, an
    /// `ssh_config` alias as in `myhost:repo.git`, a bracketed IPv6 host
    /// as in `git@[::1]:repo.git` — aren't URLs. `URL(string:)` parses
    /// them with no host at all (or the alias as a bogus scheme), which a
    /// host-based sandbox gate can only reject ("non-file URL has no host
    /// to authorize"). Rewrite them to the equivalent
    /// `ssh://[user@]host/path` using git's own rules (`connect.c`): no
    /// `://` and a colon before any slash make the remote scp-like
    /// (`url_is_local_not_ssh`), and a bracketed host ends at its closing
    /// bracket before the path colon is looked for (`host_end`). Anything
    /// else — real URLs, file URLs, local paths — passes through as is.
    /// Only the authorization sees the rewrite; libgit2 still gets the
    /// remote exactly as written.
    static func authorizationURL(forRemote url: URL) -> URL {
        guard !url.isFileURL, url.host == nil else { return url }
        // `URL(string:)` percent-encodes what a URL can't carry — an IPv6
        // literal's brackets and colons (`git@[::1]:repo.git` reads back
        // as `git@%5B%3A%3A1%5D%3Arepo.git`) — so parse it as typed.
        let remote = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard !remote.contains("://"),
              let firstColon = remote.firstIndex(of: ":"),
              !remote[..<firstColon].contains("/")
        else { return url }

        // `[::1]:path` / `user@[::1]:path`: the path colon is the first one
        // after the closing bracket, not the first in the address.
        let hostStart = remote.range(of: "@[").map { remote.index(before: $0.upperBound) }
            ?? remote.startIndex
        var pathColonSearchStart = remote.startIndex
        if remote[hostStart] == "[", let closingBracket = remote[hostStart...].firstIndex(of: "]") {
            pathColonSearchStart = closingBracket
        }
        guard let pathColon = remote[pathColonSearchStart...].firstIndex(of: ":") else { return url }

        let userAndHost = remote[..<pathColon]
        #if os(Windows)
        // `C:/repo` is a drive letter, not a host (git's `has_dos_drive_prefix`).
        if userAndHost.count == 1, userAndHost.first?.isLetter == true { return url }
        #endif
        let path = remote[remote.index(after: pathColon)...]
        let separator = path.hasPrefix("/") ? "" : "/"
        return URL(string: "ssh://\(userAndHost)\(separator)\(path)") ?? url
    }
}
