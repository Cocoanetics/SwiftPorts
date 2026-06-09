import Foundation
import libgit2

/// Heap-allocated box holding the Swift `CredentialProvider`. We pass a
/// raw pointer to this box as libgit2's `payload`, then unbox it inside
/// the `@convention(c)` trampoline. Lifetime is scoped to the duration
/// of the C call by `withCredentialPayload`.
final class CredentialBox {
    let provider: CredentialProvider
    init(_ provider: @escaping CredentialProvider) { self.provider = provider }
}

/// Runs `body` with a `(callback, payload)` pair suitable for stuffing
/// into a `git_remote_callbacks`. Pass `nil` provider to get
/// `(nil, nil)` and skip the callback entirely.
func withCredentialPayload<T>(
    _ provider: CredentialProvider?,
    _ body: (git_credential_acquire_cb?, UnsafeMutableRawPointer?) throws -> T
) rethrows -> T {
    guard let provider else { return try body(nil, nil) }
    let box = CredentialBox(provider)
    let raw = Unmanaged.passRetained(box).toOpaque()
    defer { Unmanaged<CredentialBox>.fromOpaque(raw).release() }
    return try body(credentialsTrampoline, raw)
}

/// libgit2 calls this when the transport wants credentials. We pull
/// the `CredentialBox` back out of `payload`, ask the Swift provider,
/// and translate the result into a `git_credential_*`.
///
/// Returns `0` on success, `GIT_PASSTHROUGH` to let libgit2 surface a
/// clean auth error, or `-1` if construction failed.
private let credentialsTrampoline: git_credential_acquire_cb = { outPtr, urlCStr, userCStr, allowedTypes, payload in
    guard let payload, let outPtr else { return -1 }
    let box = Unmanaged<CredentialBox>.fromOpaque(payload).takeUnretainedValue()

    let url: URL = {
        if let urlCStr, let parsed = URL(string: String(cString: urlCStr)) {
            return parsed
        }
        return URL(string: "about:blank")!
    }()
    let usernameFromURL: String? = userCStr.map { String(cString: $0) }
    let allowed = CredentialKind(rawValue: allowedTypes)

    guard let creds = box.provider(url, usernameFromURL, allowed) else {
        // GIT_PASSTHROUGH (-30) tells libgit2 "I have no credential" so
        // it surfaces an auth error rather than treating us as the
        // authority that decided to abort the whole op.
        return -30
    }

    return buildCredential(into: outPtr, from: creds)
}

private func buildCredential(
    into out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>,
    from creds: Credentials
) -> Int32 {
    switch creds {
    case .userPassword(let username, let password):
        return username.withCString { u in
            password.withCString { p in
                git_credential_userpass_plaintext_new(out, u, p)
            }
        }

    case .token(let token, let username):
        return username.withCString { u in
            token.withCString { p in
                git_credential_userpass_plaintext_new(out, u, p)
            }
        }

    case .sshKey(let username, let publicKey, let privateKey, let passphrase):
        let pubPath = publicKey?.path
        return username.withCString { u in
            withOptionalCString(pubPath) { pub in
                privateKey.path.withCString { priv in
                    withOptionalCString(passphrase) { pass in
                        git_credential_ssh_key_new(out, u, pub, priv, pass)
                    }
                }
            }
        }

    case .sshAgent(let username):
        return username.withCString { u in
            git_credential_ssh_key_from_agent(out, u)
        }

    case .username(let username):
        return username.withCString { u in
            git_credential_username_new(out, u)
        }

    case .default:
        return git_credential_default_new(out)
    }
}

private func withOptionalCString<T>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) -> T
) -> T {
    if let string { return string.withCString { body($0) } }
    return body(nil)
}
