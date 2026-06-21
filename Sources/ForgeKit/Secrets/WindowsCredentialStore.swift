#if os(Windows)
import Foundation
import WinSDK

/// Windows `SecretStore` backed by the Credential Manager (the Credential
/// Locker), which DPAPI-protects entries per-user at rest. Generic
/// credentials keyed by a `TargetName` of `"<service>:<account>"`.
///
/// Equivalent to what upstream `gh`/`glab` get from `zalando/go-keyring`
/// on Windows. The secret is stored as the credential blob (raw,
/// byte-exact UTF-8 — no NUL terminator), read back by exact length.
public struct WindowsCredentialStore: SecretStore {
    public init() {}

    /// The one and only target-name format, shared by read/write/delete
    /// (a read/write mismatch is the classic Credential-Manager bug).
    private func targetName(service: String, account: String) -> String {
        "\(service):\(account)"
    }

    public func get(service: String, account: String) async throws -> String? {
        let name = targetName(service: service, account: account)
        let result: Result<String?, Error> = name.withCString(encodedAs: UTF16.self) { namePtr in
            var credPtr: UnsafeMutablePointer<CREDENTIALW>? = nil
            if !CredReadW(namePtr, DWORD(CRED_TYPE_GENERIC), 0, &credPtr) {
                let err = GetLastError()
                if err == DWORD(ERROR_NOT_FOUND) { return .success(nil) }
                return .failure(SecretStoreError.backendError(
                    status: Int32(bitPattern: err), message: "CredReadW failed"))
            }
            guard let cred = credPtr else { return .success(nil) }
            defer { CredFree(cred) }
            let size = Int(cred.pointee.CredentialBlobSize)
            guard let blob = cred.pointee.CredentialBlob, size > 0 else {
                return .success("")
            }
            let data = Data(bytes: blob, count: size)
            return .success(String(data: data, encoding: .utf8))
        }
        return try result.get()
    }

    public func set(service: String, account: String, secret: String) async throws {
        let name = targetName(service: service, account: account)
        var bytes = Array(secret.utf8)
        let count = bytes.count
        try bytes.withUnsafeMutableBufferPointer { buffer in
            try name.withCString(encodedAs: UTF16.self) { namePtr in
                var cred = CREDENTIALW()
                cred.Type = DWORD(CRED_TYPE_GENERIC)
                cred.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                cred.TargetName = UnsafeMutablePointer(mutating: namePtr)
                cred.CredentialBlobSize = DWORD(count)
                cred.CredentialBlob = buffer.baseAddress   // nil only when count == 0
                if !CredWriteW(&cred, 0) {
                    throw SecretStoreError.backendError(
                        status: Int32(bitPattern: GetLastError()),
                        message: "CredWriteW failed")
                }
            }
        }
    }

    public func delete(service: String, account: String) async throws {
        let name = targetName(service: service, account: account)
        try name.withCString(encodedAs: UTF16.self) { namePtr in
            if !CredDeleteW(namePtr, DWORD(CRED_TYPE_GENERIC), 0) {
                let err = GetLastError()
                if err == DWORD(ERROR_NOT_FOUND) { return }   // already gone: no-op
                throw SecretStoreError.backendError(
                    status: Int32(bitPattern: err), message: "CredDeleteW failed")
            }
        }
    }
}
#endif
