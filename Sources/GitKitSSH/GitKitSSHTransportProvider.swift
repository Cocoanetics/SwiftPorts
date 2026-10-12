import GitKit
import ShellKit
import SSHKit

/// Implements GitKit's ``GitSSHTransportProvider`` over `SSHKit`'s
/// in-process SSH client (issue #113). Resolves `host`/`port`/`user`
/// the same way `ssh(1)` would: the parsed git URL's own values win,
/// falling back to whatever `ssh_config(5)` (`HostName`/`Port`/`User`/
/// `IdentityFile`/`UserKnownHostsFile`/`StrictHostKeyChecking`) resolves
/// for that host.
public struct GitKitSSHTransportProvider: GitSSHTransportProvider {
    private let sshConfigPath: String

    /// - parameter sshConfigPath: defaults to `~/.ssh/config`, exactly
    ///   like `ssh(1)` with no `-F`.
    public init(sshConfigPath: String = "~/.ssh/config") {
        self.sshConfigPath = sshConfigPath
    }

    public func openChannel(
        host: String,
        port: Int?,
        user: String?,
        command: GitSSHCommand
    ) throws -> GitSSHChannel {
        try GitKitSSHBridge.runBlocking {
            try await Self.connect(
                host: host, port: port, user: user, command: command, sshConfigPath: sshConfigPath)
        }
    }

    private static func connect(
        host: String,
        port: Int?,
        user: String?,
        command: GitSSHCommand,
        sshConfigPath: String
    ) async throws -> GitKitSSHChannel {
        let config = try await SSHConfig.load(path: sshConfigPath)
        let hostConfig = try config.resolve(host: host)

        let identities = try await IdentityLoader.loadAvailable(paths: hostConfig.identityFiles)
        let knownHosts = try await KnownHostsStore.load(paths: hostConfig.userKnownHostsFile)

        let client = try await SSHClient.connect(
            host: hostConfig.hostName,
            port: port ?? hostConfig.port,
            username: user ?? hostConfig.user ?? Shell.current.hostInfo.userName,
            identities: identities,
            knownHosts: knownHosts,
            userKnownHostsFilePath: hostConfig.userKnownHostsFile.first,
            strictHostKeyChecking: hostConfig.strictHostKeyChecking
        )

        do {
            let exec = try await client.exec(Self.remoteCommand(for: command))
            return GitKitSSHChannel(client: client, exec: exec)
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// `<command> '<path>'` — exactly how `GitSSHTransportProvider.openChannel`'s
    /// doc comment (in GitKit's `SSHTransport.swift`) says libgit2 expects the
    /// remote command to be invoked, mirroring what `ssh host "git-upload-pack
    /// '/repo.git'"` sends today. `path` is shell-quoted (see
    /// ``shellQuote(_:)``) since it comes straight from a parsed remote URL.
    private static func remoteCommand(for command: GitSSHCommand) -> String {
        switch command {
        case .uploadPack(let path): return "git-upload-pack \(shellQuote(path))"
        case .receivePack(let path): return "git-receive-pack \(shellQuote(path))"
        case .uploadArchive(let path): return "git-upload-archive \(shellQuote(path))"
        }
    }

    /// Shell-quotes `path` exactly like git's own `sq_quote_buf` (`quote.c`),
    /// which git's SSH transport uses to build this same remote command:
    /// wrap in single quotes, and within that, turn each embedded `'` into
    /// `'\''` (close the quote, emit an escaped literal quote, reopen) and
    /// each `!` into `'\!'` (close, emit an escaped literal `!`, reopen —
    /// defends a remote login shell that is csh/tcsh, where `!` triggers
    /// history expansion even inside single quotes). Without this, a path
    /// containing `'` would terminate the quoting early and let the rest of
    /// the path execute as shell syntax on the remote.
    static func shellQuote(_ path: String) -> String {
        var quoted = "'"
        for character in path {
            switch character {
            case "'": quoted += "'\\''"
            case "!": quoted += "'\\!'"
            default: quoted.append(character)
            }
        }
        quoted += "'"
        return quoted
    }
}
