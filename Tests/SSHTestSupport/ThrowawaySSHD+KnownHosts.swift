#if os(macOS) || os(Linux)
import Foundation

extension ThrowawaySSHD {
    /// A `known_hosts` line pinning this daemon's host key to `[127.0.0.1]:<port>`, without a
    /// trailing newline.
    public func knownHostsLine() throws -> String {
        try Self.knownHostsLine(hostPublicKeyPath: hostPublicKeyPath, port: port)
    }

    /// A `known_hosts` line pinning the key in `hostPublicKeyPath` to `127.0.0.1` on `port` —
    /// pass some other key to provoke a host-key mismatch.
    public static func knownHostsLine(hostPublicKeyPath: String, port: Int) throws -> String {
        let keyLine = try String(contentsOfFile: hostPublicKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = keyLine.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2 else {
            throw ThrowawaySSHDError("not an OpenSSH public key: \(hostPublicKeyPath)")
        }
        let hostField = port == 22 ? "127.0.0.1" : "[127.0.0.1]:\(port)"
        return "\(hostField) \(fields[0]) \(fields[1])"
    }
}
#endif
