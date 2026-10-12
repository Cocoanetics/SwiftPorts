/// Errors thrown by `SSHKit`.
///
/// `description` carries the exact wording OpenSSH's `ssh(1)` client prints to stderr for the
/// equivalent failure (quoted from `openssh-portable` at the pinned commit — see Docs/SSH.md),
/// since a future CLI layer (`SSHCommand`, #114) needs to reproduce it byte-for-byte. Every case
/// here corresponds to a `fatal()` call in OpenSSH, which always exits 255.
public enum SSHError: Error, CustomStringConvertible, Sendable {
    /// Host-key verification failed: a new host under strict checking, a changed host key, or a
    /// declined interactive prompt. `lines` is the full block of diagnostic text OpenSSH prints
    /// before its final, constant "Host key verification failed." line (`sshconnect2.c` line 104).
    case hostKeyVerificationFailed(lines: [String])

    /// All configured authentication methods were exhausted. Mirrors `userauth()` in
    /// `sshconnect2.c` line 543: `fatal("%s@%s: Permission denied (%s).", user, host, authlist)`.
    case permissionDenied(user: String, host: String, methods: [String])

    /// An `IdentityFile` path does not exist.
    case identityFileNotFound(path: String)

    /// An identity file exists but isn't a key type or encoding this port supports (encrypted
    /// keys and RSA are out of scope — see AGENTS.md's fidelity rule and issue #112).
    case unsupportedKeyFormat(path: String, reason: String)

    /// A `known_hosts` line couldn't be parsed.
    case invalidKnownHostsEntry(path: String, line: Int, reason: String)

    /// An `ssh_config` file had unrecognized keywords. Mirrors `read_config_file_depth()` in
    /// `readconf.c` line 2680: `fatal("%s: terminating, %d bad configuration options", ...)`.
    case badConfigurationOptions(path: String, count: Int)

    /// An explicit `-F` config file could not be opened. The default per-user
    /// config remains optional, matching `process_config_files()` in `ssh.c`.
    case cannotOpenUserConfigFile(path: String, reason: String)

    public var description: String {
        switch self {
        case .hostKeyVerificationFailed(let lines):
            return (lines + ["Host key verification failed."]).joined(separator: "\n")
        case .permissionDenied(let user, let host, let methods):
            return "\(user)@\(host): Permission denied (\(methods.joined(separator: ",")))."
        case .identityFileNotFound(let path):
            return "\(path): No such file or directory"
        case .unsupportedKeyFormat(let path, let reason):
            return "\(path): \(reason)"
        case .invalidKnownHostsEntry(let path, let line, let reason):
            return "\(path): line \(line): \(reason)"
        case .badConfigurationOptions(let path, let count):
            return "\(path): terminating, \(count) bad configuration options"
        case .cannotOpenUserConfigFile(let path, let reason):
            return "Can't open user config file \(path.prefix(100)): \(reason.prefix(100))"
        }
    }
}
