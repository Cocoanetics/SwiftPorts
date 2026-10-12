/// Non-fatal outcomes of trying to decrypt an encrypted identity file. Unlike `SSHError`, neither
/// case corresponds to one of `ssh(1)`'s `fatal()` calls: `load_identity_file` in `sshconnect2.c`
/// just returns `NULL` for both and moves on — `IdentityLoader.loadAvailable` mirrors that by
/// catching this error and skipping the identity rather than aborting.
enum SSHIdentityDecryptionError: Error {
    /// The passphrase prompt returned nothing, matching `load_identity_file`'s own "no passphrase
    /// given, try next key" when the user enters an empty passphrase.
    case declined(path: String)

    /// The passphrase was wrong: a GCM tag mismatch, or (for `aes256-ctr`, which has no integrity
    /// check of its own) a checkint mismatch after decryption. Matches `SSH_ERR_KEY_WRONG_PASSPHRASE`
    /// in `private2_decrypt()` (`sshkey.c`).
    case wrongPassphrase(path: String)
}
