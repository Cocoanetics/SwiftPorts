#if os(macOS) || os(Linux)
import Foundation

extension ThrowawaySSHD {
    /// Writes an `ssh_config` to `path` with one `Host alias` block resolving to this daemon as
    /// the current user, so an `ssh://<alias>/<path>` URL or `<alias>:<path>` remote reaches it.
    public func writeSSHConfig(
        to path: String, alias: String, identityPath: String, knownHostsPath: String,
        strictHostKeyChecking: String = "yes"
    ) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
            Host \(alias)
                HostName 127.0.0.1
                Port \(port)
                User \(ProcessInfo.processInfo.environment["USER"] ?? NSUserName())
                IdentityFile \(identityPath)
                UserKnownHostsFile \(knownHostsPath)
                StrictHostKeyChecking \(strictHostKeyChecking)
            """
        try config.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
