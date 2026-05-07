import Foundation

/// Thread-safe in-process secret store. Default for tests and for
/// embedders that don't want any disk persistence.
///
/// Values are dropped when the process exits. NEVER use as a "real"
/// store — gh-style commands assume secrets survive across runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String
    }
    // `NSLock.withLock(_:)` is available on every platform we target
    // and is async-safe (the closure can't suspend). Switching to
    // `Synchronization.Mutex` would force the package's deployment
    // bound up to macOS 15 / iOS 18, which we deliberately avoid so
    // SwiftBash and other embedders can target their existing OS
    // ranges. The hot path is at most one map lookup per call, so
    // the lock-vs-mutex performance delta is irrelevant.
    private let lock = NSLock()
    private var storage: [Key: String] = [:]

    public init() {}

    public func get(service: String, account: String) async throws -> String? {
        lock.withLock { storage[Key(service: service, account: account)] }
    }

    public func set(service: String, account: String, secret: String) async throws {
        lock.withLock { storage[Key(service: service, account: account)] = secret }
    }

    public func delete(service: String, account: String) async throws {
        lock.withLock { storage[Key(service: service, account: account)] = nil }
    }
}
