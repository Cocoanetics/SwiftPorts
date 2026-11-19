import Foundation

/// SSH coordinates git-lfs keeps beside an endpoint (`ssh.SSHMetadata`),
/// plus the user and host a later transfer can dial separately.
/// `userAndHost` is what `git lfs env` prints.
public struct LFSSSHMetadata: Sendable, Equatable {
    public var user: String
    public var host: String
    public var port: String
    public var path: String
    public var userAndHost: String

    public init(user: String = "", host: String = "", port: String = "", path: String = "", userAndHost: String = "") {
        self.user = user
        self.host = host
        self.port = port
        self.path = path
        self.userAndHost = userAndHost
    }

    public static let empty = LFSSSHMetadata()
}

/// How to reach a Git LFS server (`lfshttp.Endpoint`).
public struct LFSEndpoint: Sendable, Equatable {
    /// The HTTPS (or file) URL a batch request is sent to.
    public var url: String
    public var ssh: LFSSSHMetadata
    /// `download` or `upload`.
    public var operation: String
    /// The URL before it was rewritten to HTTPS, when there was one.
    public var originalURL: String

    public init(url: String = "", ssh: LFSSSHMetadata = .empty, operation: String = "", originalURL: String = "") {
        self.url = url
        self.ssh = ssh
        self.operation = operation
        self.originalURL = originalURL
    }

    /// `lfshttp.UrlUnknown`.
    public static let unknown = "<unknown>"
}
