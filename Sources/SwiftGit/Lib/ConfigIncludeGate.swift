import Foundation
import CGitKit
import ShellKit

/// Lets libgit2 read an `[include]` file only once the sandbox has
/// authorised it. The sandbox gate is async and libgit2 asks synchronously,
/// so a file not yet authorised is refused and remembered: the caller
/// authorises it, then reads the config again.
final class ConfigIncludeGate: @unchecked Sendable {
    private let enforcing: Bool
    private let lock = NSLock()
    private var allowed: Set<String> = []
    private var refused: String?

    /// - Parameter enforcing: whether there is a sandbox to ask; without
    ///   one every include is read, as git does.
    init(enforcing: Bool) {
        self.enforcing = enforcing
    }

    /// Whether `path` may be read; one that may not is kept as the next
    /// one to authorise.
    fileprivate func permits(_ path: String) -> Bool {
        guard enforcing else { return true }
        return lock.withLock {
            if allowed.contains(path) { return true }
            refused = path
            return false
        }
    }

    private func takeRefused() -> String? {
        lock.withLock {
            defer { refused = nil }
            return refused
        }
    }

    private func allow(_ path: String) {
        lock.withLock { _ = allowed.insert(path) }
    }

    /// Authorises the file the last read was refused, so the next read can
    /// open it. `false` when nothing was refused (the failure was not the
    /// gate's). Throws the sandbox's denial.
    func authorizeRefused() async throws -> Bool {
        guard let path = takeRefused() else { return false }
        try await Shell.authorize(URL(fileURLWithPath: path))
        allow(path)
        return true
    }

    /// Runs `body` with this gate deciding the include files its config
    /// reads on the calling thread.
    func run<T>(_ body: () throws -> T) rethrows -> T {
        var previousCallback: gitkit_config_include_cb?
        var previousPayload: UnsafeMutableRawPointer?
        let payload = Unmanaged.passUnretained(self).toOpaque()
        gitkit_config_set_thread_include_callback(
            { path, _, _, payload in
                guard let path, let payload else { return 1 }
                let gate = Unmanaged<ConfigIncludeGate>.fromOpaque(payload).takeUnretainedValue()
                return gate.permits(String(cString: path)) ? 0 : 1
            }, payload, &previousCallback, &previousPayload)
        defer {
            gitkit_config_set_thread_include_callback(previousCallback, previousPayload, nil, nil)
        }
        return try withExtendedLifetime(self) { try body() }
    }
}
