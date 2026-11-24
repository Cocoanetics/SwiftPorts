#if os(macOS) || os(Linux)
import Foundation

extension ThrowawaySSHD {
    /// Writes an `ssh_config` to `path` with one `Host alias` block resolving to this daemon as
    /// the current user, so an `ssh://<alias>/<path>` URL or `<alias>:<path>` remote reaches it.
    /// `IdentitiesOnly yes` keeps a system `ssh` from offering `ssh-agent` keys first and hitting
    /// the daemon's `MaxAuthTries` before the throwaway identity.
    /// Paths are double-quoted, so they may contain whitespace but not `"` or a newline.
    public func writeSSHConfig(
        to path: String, alias: String, identityPath: String, knownHostsPath: String,
        strictHostKeyChecking: String = "yes"
    ) throws {
        let identityArgument = try Self.quotedConfigArgument(identityPath)
        let knownHostsArgument = try Self.quotedConfigArgument(knownHostsPath)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
            Host \(alias)
                HostName 127.0.0.1
                Port \(port)
                User \(ProcessInfo.processInfo.environment["USER"] ?? NSUserName())
                IdentityFile \(identityArgument)
                IdentitiesOnly yes
                UserKnownHostsFile \(knownHostsArgument)
                StrictHostKeyChecking \(strictHostKeyChecking)
            """
        try config.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `ssh_config(5)` splits arguments on whitespace unless they're double-quoted.
    private static func quotedConfigArgument(_ path: String) throws -> String {
        guard !path.contains("\""), !path.contains(where: \.isNewline) else {
            throw ThrowawaySSHDError("can't quote path for ssh_config: \(path)")
        }
        return "\"\(path)\""
    }
}
#endif
