import Foundation

public enum SSHRevocationList {
    /// Text key revocations only. A binary KRL is deliberately rejected, never treated as empty.
    public static func check(_ key: SSHPublicKey, data: Data) throws {
        guard !data.starts(with: Array("SSHKRL\n\0".utf8)), let text = String(data: data, encoding: .utf8) else {
            throw SSHKeygenError("Binary key revocation lists are unsupported")
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if try SSHPublicKey(openSSHLine: trimmed) == key { throw SSHKeygenError("Key is revoked") }
        }
    }
}
