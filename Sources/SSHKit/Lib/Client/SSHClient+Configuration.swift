import ShellKit

extension SSHClient {
    /// Connects using the SSH URL's overrides and the matching `ssh_config`
    /// host block. Shared by the Git transport and LFS authentication.
    public static func connect(
        host: String, port: Int? = nil, user: String? = nil,
        configPath: String = "~/.ssh/config", commandLineOptions: [String] = [],
        requireConfigFile: Bool = false
    ) async throws -> SSHClient {
        let config = try await SSHConfig.load(
            path: configPath, commandLineOptions: commandLineOptions, requireFile: requireConfigFile)
        let resolved = try config.resolve(host: host)
        let identities = try await IdentityLoader.loadAvailable(paths: resolved.identityFiles)
        let knownHosts = try await KnownHostsStore.load(paths: resolved.userKnownHostsFile)
        return try await connect(
            host: resolved.hostName,
            port: port ?? resolved.port,
            username: user ?? resolved.user ?? Shell.current.hostInfo.userName,
            identities: identities,
            knownHosts: knownHosts,
            userKnownHostsFilePath: resolved.userKnownHostsFile.first,
            strictHostKeyChecking: resolved.strictHostKeyChecking)
    }
}
