import Foundation
import CGitKit

/// Process-wide libgit2 init / shutdown bookkeeping.
///
/// `git_libgit2_init()` is reference-counted by libgit2 itself; we just
/// have to make sure it's been called once before any other git_* call.
/// We intentionally never call `git_libgit2_shutdown()` — the library is
/// meant to live for the duration of the process, and shutting down
/// while another thread is mid-operation is unsafe.
public enum Libgit2 {
    private static let initialized: Bool = {
        let rc = git_libgit2_init()
        precondition(rc >= 0, "git_libgit2_init failed with \(rc)")
        return true
    }()

    /// Public so hosts that poke libgit2's process-global state *before*
    /// any `Repository` call (e.g. option bridges setting search paths)
    /// can guarantee the library is initialized first.
    public static func ensureInitialized() {
        _ = initialized
    }
}
