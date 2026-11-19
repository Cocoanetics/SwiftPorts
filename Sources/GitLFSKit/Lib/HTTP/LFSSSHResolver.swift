import Foundation
import SSHKit

/// Async SSH authentication and the operation-specific cache from `lfshttp/ssh.go`.
/// Batch request builders consume `href` as their base URL and set `header`
/// before passing the request to `LFSClient`.
public actor LFSSSHResolver {
    typealias Authenticate = @Sendable (LFSEndpoint, String) async throws -> Data
    struct AuthenticateUnavailable: Error {}
    private let finder: LFSEndpointFinder
    private let authenticate: Authenticate
    private let now: @Sendable () -> Date
    private var cache: [String: LFSSSHAuthResponse] = [:]

    public init(finder: LFSEndpointFinder, sshConfigPath: String = "~/.ssh/config") {
        self.finder = finder
        now = { Date() }
        authenticate = { endpoint, command in
            let options = try LFSSSHCommandOptions(configuration: finder.configuration, configPath: sshConfigPath)
            var directives = options.directives
            if !endpoint.ssh.port.isEmpty { directives.append("Port \(endpoint.ssh.port)") }
            if !endpoint.ssh.user.isEmpty { directives.append("User \(endpoint.ssh.user)") }
            let client = try await SSHClient.connect(
                host: endpoint.ssh.host,
                configPath: options.configPath, commandLineOptions: directives,
                requireConfigFile: options.requireConfigFile)
            do {
                let exec = try await client.exec(command)
                try await exec.closeStdin()
                async let output = Self.collect(exec.stdout)
                async let errors = Self.collect(exec.stderr)
                let status = try await exec.exitStatus
                let (stdout, stderr) = await (output, errors)
                try await exec.waitUntilClosed()
                try? await client.close()
                guard status == 0 else {
                    let message = String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.authenticateUnavailable(status: status, stderr: message) {
                        throw AuthenticateUnavailable()
                    }
                    let reason = "exit status \(status)"
                    throw LFSClientError(message.isEmpty ? reason : "\(message): \(reason)")
                }
                return stdout
            } catch {
                try? await client.close()
                throw error
            }
        }
    }

    init(finder: LFSEndpointFinder, now: @escaping @Sendable () -> Date, authenticate: @escaping Authenticate) {
        self.finder = finder
        self.now = now
        self.authenticate = authenticate
    }

    /// `sshResolveWithRetries`. An explicit endpoint operation wins over the
    /// method (`GET`/`HEAD` download, otherwise upload).
    public func resolve(_ endpoint: LFSEndpoint, method: String) async throws -> LFSSSHAuthResponse {
        if let mode = finder.urlConfig.get(prefix: "lfs", url: endpoint.originalURL, key: "sshtransfer"),
           mode != "negotiate" && mode != "never" {
            throw LFSClientError("git-lfs-authenticate has been disabled by request")
        }
        guard !endpoint.ssh.userAndHost.isEmpty else {
            return try JSONDecoder().decode(LFSSSHAuthResponse.self, from: Data("{}".utf8))
        }
        let key = [endpoint.ssh.userAndHost, endpoint.ssh.port, endpoint.ssh.path,
                   Self.operation(endpoint, method: method)].joined(separator: "//")
        if finder.cacheCredentials, let cached = cache[key], !cached.expired(at: now()) { return cached }
        let attempts = max(0, Int(finder.configuration.get("lfs.ssh.retries") ?? "") ?? 5) + 1
        for attempt in 0..<attempts {
            do {
                let started = now()
                let data = try await authenticate(endpoint, Self.remoteCommand(endpoint, method: method))
                var response = try JSONDecoder().decode(LFSSSHAuthResponse.self, from: data)
                response.received(
                    at: started, defaultTTL: Int(finder.configuration.get("lfs.defaulttokenttl") ?? "") ?? 0)
                if finder.cacheCredentials { cache[key] = response }
                return response
            } catch {
                if error is AuthenticateUnavailable {
                    return try JSONDecoder().decode(LFSSSHAuthResponse.self, from: Data("{}".utf8))
                }
                if error is CancellationError || Task.isCancelled || attempt == attempts - 1 { throw error }
            }
        }
        throw LFSClientError("too many authentication attempts")
    }

    static func remoteCommand(_ endpoint: LFSEndpoint, method: String) -> String {
        ["git-lfs-authenticate", endpoint.ssh.path, operation(endpoint, method: method)]
            .map(shellQuote).joined(separator: " ")
    }

    static func authenticateUnavailable(status: Int32, stderr: String) -> Bool {
        if status == 127 { return true }
        guard status != 0 else { return false }
        let message = stderr.lowercased()
        return [
            "git-lfs-authenticate: not found",
            "git-lfs-authenticate: command not found",
            "git-lfs-authenticate: no such file",
            "command not found: git-lfs-authenticate"
        ].contains { message.contains($0) }
    }

    private static func operation(_ endpoint: LFSEndpoint, method: String) -> String {
        endpoint.operation.isEmpty
            ? (["GET", "HEAD"].contains(method) ? "download" : "upload") : endpoint.operation
    }

    /// git-lfs `subprocess.ShellQuoteSingle`: simple shell words remain bare.
    static func shellQuote(_ value: String) -> String {
        let safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@/.-"
        if !value.isEmpty && value.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func collect(_ stream: AsyncStream<[UInt8]>) async -> Data {
        var data = Data()
        for await bytes in stream { data.append(contentsOf: bytes) }
        return data
    }
}
