import Crypto
import Foundation

/// Thrown for the same "nothing crazy" parameter-sanity guard `bcrypt_pbkdf()` checks before
/// doing any work (`bcrypt_pbkdf.c`'s `bad:` label) — a malformed `kdfoptions` field in an
/// `openssh-key-v1` container (zero rounds, empty salt, absurd key length), not a wrong
/// passphrase.
enum BCryptPBKDFError: Error {
    case invalidParameters
}

/// A from-scratch Swift port of OpenBSD's `bcrypt_pbkdf()` (`openbsd-compat/bcrypt_pbkdf.c`), the
/// KDF `openssh-key-v1` uses to turn a passphrase into a cipher key + IV (`PROTOCOL.key` §2:
/// `kdfname "bcrypt"`). PBKDF2 structure around the "bcrypt hash" primitive (SHA-512 pre/post
/// processing around an Eksblowfish-derived keystream, `BlowfishContext`), with the same
/// non-linear output-interleaving `bcrypt_pbkdf.c` itself calls out as a deviation from plain
/// PBKDF2.
enum BCryptPBKDF {
    /// `BCRYPT_HASHSIZE` (`BCRYPT_WORDS * 4` = `8 * 4`).
    private static let hashSize = 32

    static func derive(passphrase: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) throws -> [UInt8] {
        guard
            rounds >= 1,
            !passphrase.isEmpty,
            !salt.isEmpty,
            keyLength > 0,
            keyLength <= Self.hashSize * Self.hashSize,
            salt.count <= (1 << 20)
        else {
            throw BCryptPBKDFError.invalidParameters
        }

        let stride = (keyLength + Self.hashSize - 1) / Self.hashSize
        var amt = (keyLength + stride - 1) / stride
        let originalKeyLength = keyLength

        var key = [UInt8](repeating: 0, count: keyLength)
        var countedSalt = salt + [0, 0, 0, 0]

        let sha2pass = Array(SHA512.hash(data: Data(passphrase)))

        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            countedSalt[salt.count + 0] = UInt8((count >> 24) & 0xff)
            countedSalt[salt.count + 1] = UInt8((count >> 16) & 0xff)
            countedSalt[salt.count + 2] = UInt8((count >> 8) & 0xff)
            countedSalt[salt.count + 3] = UInt8(count & 0xff)

            // First round: salt is `salt || count`.
            var sha2salt = Array(SHA512.hash(data: Data(countedSalt)))
            var tmpout = Self.bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmpout

            // Subsequent rounds: salt is the previous round's output, XORed into `out`.
            if rounds > 1 {
                for _ in 1..<rounds {
                    sha2salt = Array(SHA512.hash(data: Data(tmpout)))
                    tmpout = Self.bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                    for j in 0..<Self.hashSize {
                        out[j] ^= tmpout[j]
                    }
                }
            }

            // "pbkdf2 deviation: output the key material non-linearly."
            amt = min(amt, remaining)
            var produced = 0
            for i in 0..<amt {
                let dest = i * stride + Int(count - 1)
                guard dest < originalKeyLength else { break }
                key[dest] = out[i]
                produced += 1
            }
            remaining -= produced
            count += 1
        }

        return key
    }

    /// `bcrypt_hash()`: the Eksblowfish key schedule run against `sha2salt`/`sha2pass`, then used
    /// to encrypt the fixed 32-byte magic string "OxychromaticBlowfishSwatDynamite" 64 times.
    private static func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = BlowfishContext()
        state.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0State(key: sha2salt)
            state.expand0State(key: sha2pass)
        }

        let ciphertext = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var j = 0
        var cdata = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            cdata[i] = BlowfishContext.streamToWord(ciphertext, current: &j)
        }
        for _ in 0..<64 {
            state.encipherBlocks(&cdata)
        }

        // Little-endian word-to-byte copy-out, exactly as `bcrypt_hash()` writes it.
        var out = [UInt8](repeating: 0, count: Self.hashSize)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8((cdata[i] >> 24) & 0xff)
            out[4 * i + 2] = UInt8((cdata[i] >> 16) & 0xff)
            out[4 * i + 1] = UInt8((cdata[i] >> 8) & 0xff)
            out[4 * i + 0] = UInt8(cdata[i] & 0xff)
        }
        return out
    }
}
