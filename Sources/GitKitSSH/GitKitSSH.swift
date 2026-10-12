import GitKit

/// Opt-in registration of ``GitKitSSHTransportProvider`` as GitKit's SSH
/// transport (issue #113). Never called by `SwiftGit`/`GitCommand` — a
/// host that wants in-process SSH (SwiftPorts' `git` executable,
/// SwiftBash, MissionControl) calls `install()` once at startup. Without
/// it, GitKit's `ssh://`/scp-style remotes keep using libgit2's
/// `ssh_exec` fallback (which shells out to `/usr/bin/ssh` per call and
/// can't run on iOS).
public enum GitKitSSH {
    /// Registers the provider. See ``GitSSHTransport/register(_:)``'s
    /// synchronization contract — call this once, before any git
    /// network operation starts.
    ///
    /// - parameter sshConfigPath: forwarded to
    ///   ``GitKitSSHTransportProvider``; defaults to `~/.ssh/config`,
    ///   exactly like `ssh(1)` with no `-F`.
    public static func install(sshConfigPath: String = "~/.ssh/config") throws {
        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: sshConfigPath))
    }

    /// Restores libgit2's `ssh_exec` fallback. See
    /// ``GitSSHTransport/unregister()``'s synchronization contract
    /// before calling this while a git network operation might be in
    /// flight.
    public static func uninstall() {
        GitSSHTransport.unregister()
    }
}
