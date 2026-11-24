#if os(macOS) || os(Linux)
import Foundation

/// A disposable, unencrypted ed25519 client key pair made by the system `ssh-keygen`, for
/// authorizing against a `ThrowawaySSHD`.
public struct ThrowawaySSHIdentity: Sendable {
    /// The private key, for `IdentityFile` or `IdentityLoader`.
    public let privateKeyPath: String

    /// The public key, for `ThrowawaySSHD.start(authorizingPublicKeyPath:)`.
    public var publicKeyPath: String { privateKeyPath + ".pub" }

    /// Writes `id_ed25519` and `id_ed25519.pub` into `directory`, creating it if needed.
    public static func generate(in directory: URL) throws -> ThrowawaySSHIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("id_ed25519").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", path, "-q"]
        try process.run()
        ThrowawaySSHD.waitForExit(process, timeout: 60)
        guard process.terminationStatus == 0 else {
            throw ThrowawaySSHDError("ssh-keygen failed")
        }
        return ThrowawaySSHIdentity(privateKeyPath: path)
    }
}
#endif
