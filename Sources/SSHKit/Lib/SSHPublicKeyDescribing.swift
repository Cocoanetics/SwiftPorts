import Crypto
import Foundation
import NIOSSH

/// Small helpers for deriving OpenSSH-visible facts about a `NIOSSHPublicKey` — its wire
/// algorithm identifier, `sshkey_type()`'s short display name, and its default (SHA256)
/// fingerprint — without reaching into `NIOSSH`'s `internal` wire-format helpers.
enum SSHPublicKeyDescribing {
    /// e.g. `"ssh-ed25519"`, `"ecdsa-sha2-nistp256"`.
    static func algorithmIdentifier(for key: NIOSSHPublicKey) -> String {
        let full = String(openSSHPublicKey: key)
        return String(full.prefix { $0 != " " })
    }

    /// `sshkey_type()`'s short name (`ssh-ed25519.c` line 291, `ssh-ecdsa.c` lines 509/533/557):
    /// `"ED25519"` or `"ECDSA"`.
    static func shortTypeName(for key: NIOSSHPublicKey) -> String {
        switch Self.algorithmIdentifier(for: key) {
        case "ssh-ed25519": return "ED25519"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return "ECDSA"
        case let other: return other.uppercased()
        }
    }

    /// The default (`FingerprintHash sha256`) fingerprint format: `"SHA256:"` + unpadded base64
    /// of the SHA-256 digest of the public key's wire-format blob.
    static func sha256Fingerprint(for key: NIOSSHPublicKey) -> String {
        let full = String(openSSHPublicKey: key)
        guard
            let spaceIndex = full.firstIndex(of: " "),
            let blob = Data(base64Encoded: String(full[full.index(after: spaceIndex)...]))
        else {
            return "SHA256:unknown"
        }
        let digest = SHA256.hash(data: blob)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}
