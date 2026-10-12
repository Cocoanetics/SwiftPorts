/// The resolved `ssh_config` settings for one destination host — the result of applying every
/// matching `Host` block's first-value-wins keywords (`readconf.c`'s `fill_default_options()`
/// supplies the same defaults this type's `init` does).
public struct SSHHostConfig: Sendable, Equatable {
    /// The real hostname to connect to. Defaults to the name passed to `SSHConfig.resolve(host:)`.
    public var hostName: String

    /// Defaults to 22.
    public var port: Int

    /// `nil` when unset — the caller supplies its own default (the local username), matching how
    /// `ssh_config(5)` leaves `User` unset rather than hardcoding a default.
    public var user: String?

    /// Paths to try, in order. Defaults to this port's narrowed subset of OpenSSH's default
    /// `IdentityFile` list (`readconf.c` lines 2930-2941): `~/.ssh/id_ecdsa`, `~/.ssh/id_ed25519` —
    /// RSA and security-key (`_sk`) variants dropped since this port never accepts them (see
    /// Docs/SSH.md).
    public var identityFiles: [String]

    /// When true, only the configured `identityFiles` are offered — never identities discovered
    /// any other way. Defaults to false.
    public var identitiesOnly: Bool

    /// Defaults to `~/.ssh/known_hosts`, `~/.ssh/known_hosts2` (`readconf.c` lines 2958-2961).
    public var userKnownHostsFile: [String]

    /// Defaults to `.ask`.
    public var strictHostKeyChecking: SSHStrictHostKeyChecking

    public init(
        hostName: String,
        port: Int = 22,
        user: String? = nil,
        identityFiles: [String] = SSHHostConfig.defaultIdentityFiles,
        identitiesOnly: Bool = false,
        userKnownHostsFile: [String] = SSHHostConfig.defaultUserKnownHostsFiles,
        strictHostKeyChecking: SSHStrictHostKeyChecking = .ask
    ) {
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFiles = identityFiles
        self.identitiesOnly = identitiesOnly
        self.userKnownHostsFile = userKnownHostsFile
        self.strictHostKeyChecking = strictHostKeyChecking
    }

    public static let defaultIdentityFiles = ["~/.ssh/id_ecdsa", "~/.ssh/id_ed25519"]

    public static let defaultUserKnownHostsFiles = ["~/.ssh/known_hosts", "~/.ssh/known_hosts2"]
}
