import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` config operations
// (`GitKit/Repository+Config.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Read a config value (`git config --get <name>`). Returns nil
    /// when the key isn't set.
    public func configGet(_ name: String, scope: ConfigScope? = nil) async throws -> String? {
        try await withRepository { try $0.configGet(name, scope: scope) }
    }

    /// Set a config value, matching `git config <name> <value>`.
    public func configSet(_ name: String, _ value: String, scope: ConfigScope = .local) async throws {
        try await withRepository { try $0.configSet(name, value, scope: scope) }
    }

    /// Remove a config entry. Returns true if removed, false if absent.
    @discardableResult
    public func configUnset(_ name: String, scope: ConfigScope = .local) async throws -> Bool {
        try await withRepository { try $0.configUnset(name, scope: scope) }
    }

    /// Walk every config entry visible to the repo — matches `git config --list`.
    public func configList() async throws -> [(name: String, value: String)] {
        try await withRepository { try $0.configList() }
    }
}
