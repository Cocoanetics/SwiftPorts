import Crypto
import Foundation

/// The hashed `known_hosts` host-field scheme from `hostfile.c`'s `host_hash()`/`extract_salt()`
/// (lines 69-150): `HASH_MAGIC "|1|"` + base64 salt + `HASH_DELIM '|'` + base64
/// `HMAC-SHA1(key: salt, message: hostname)`. The salt is the HMAC-SHA1 digest size, 20 bytes
/// (`ssh_hmac_bytes(SSH_DIGEST_SHA1)`).
enum HostKeyHashing {
    static let magic = "|1|"

    static func hash(host: String, salt: [UInt8] = (0..<20).map { _ in UInt8.random(in: .min ... .max) }) -> String {
        let key = SymmetricKey(data: salt)
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8), using: key)
        let saltBase64 = Data(salt).base64EncodedString()
        let codeBase64 = Data(code).base64EncodedString()
        return "\(magic)\(saltBase64)|\(codeBase64)"
    }

    static func matches(host: String, hashedField: String) -> Bool {
        guard hashedField.hasPrefix(magic) else {
            return false
        }
        let remainder = hashedField.dropFirst(magic.count)
        let parts = remainder.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            let salt = Data(base64Encoded: String(parts[0])),
            let expected = Data(base64Encoded: String(parts[1]))
        else {
            return false
        }

        let key = SymmetricKey(data: salt)
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8), using: key)
        return Data(code) == expected
    }
}
