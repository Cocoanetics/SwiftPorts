import Foundation
import CGitKit
import GitKit

extension GitClient {
    /// `git ls-remote --heads <remote>`, used by Git LFS's `calcSkippedRefs`.
    /// Only reads the advertisement; no objects or local refs are updated.
    @_spi(GitLFSKit) public func remoteHeads(remote: String) async throws -> [String] {
        let connection = try await resolveRemoteOperand(remote)
        return try await withRepository { repository in
            var handle: OpaquePointer?
            try Self.check(git_remote_create_anonymous(&handle, Self.handle(of: repository), connection.location))
            defer { git_remote_disconnect(handle); git_remote_free(handle) }
            // Connect to exactly the already-rewritten, authorized location, without applying aliases twice.
            try Self.check(git_remote_set_instance_url(handle, connection.location))
            var callbacks = git_remote_callbacks()
            try Self.check(git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)))
            callbacks.credentials = Self.remoteHeadsCredentials
            var provider = credentials
            return try withUnsafeMutablePointer(to: &provider) { payload in
                callbacks.payload = UnsafeMutableRawPointer(payload)
                try Self.check(git_remote_connect(handle, GIT_DIRECTION_FETCH, &callbacks, nil, nil))
                var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
                var count = 0
                try Self.check(git_remote_ls(&heads, &count, handle))
                var names: [String] = []
                for index in 0..<count {
                    guard let name = heads?[index]?.pointee.name else { continue }
                    let ref = String(cString: name)
                    if ref.hasPrefix("refs/heads/") { names.append(ref) }
                }
                return names
            }
        }
    }

    private static let remoteHeadsCredentials: git_credential_acquire_cb = { out, url, username, allowed, payload in
        guard let out, let payload,
              let provider = payload.assumingMemoryBound(to: CredentialProvider?.self).pointee,
              let url, let parsed = URL(string: String(cString: url)),
              let credential = provider(parsed, username.map { String(cString: $0) }, CredentialKind(rawValue: allowed))
        else { return GIT_PASSTHROUGH.rawValue }
        return makeRemoteHeadsCredential(credential, into: out)
    }

    private static func makeRemoteHeadsCredential(
        _ credential: Credentials, into out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>
    ) -> Int32 {
        switch credential {
        case .userPassword(let username, let password), .token(let password, let username):
            return git_credential_userpass_plaintext_new(out, username, password)
        case .sshKey(let username, let publicKey, let privateKey, let passphrase):
            return git_credential_ssh_key_new(out, username, publicKey?.path, privateKey.path, passphrase)
        case .sshAgent(let username):
            return git_credential_ssh_key_from_agent(out, username)
        case .username(let username):
            return git_credential_username_new(out, username)
        case .default:
            return git_credential_default_new(out)
        }
    }
}
