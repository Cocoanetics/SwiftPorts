import Foundation
import CGitKit
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

    /// A boolean config value as git reads one (`true`/`yes`/`on`, any
    /// nonzero integer, a key without a value), or `nil` when unset.
    /// Anything else throws git's "bad boolean config value".
    public func configBool(_ name: String) async throws -> Bool? {
        guard let value = try await configGet(name) else { return nil }
        return try Self.parseGitBool(value, key: name)
    }

    /// git's boolean parsing (`git_config_parse_bool`) and its error,
    /// which names the key the way git spells it (section and variable
    /// lowercased: `push.autosetupremote`).
    static func parseGitBool(_ value: String, key: String) throws -> Bool {
        var parsed: CInt = 0
        let result = value.withCString { git_config_parse_bool(&parsed, $0) }
        guard result == 0 else {
            var canonical = key.lowercased()
            if let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first < last {
                canonical = key[..<first].lowercased() + key[first..<last] + key[last...].lowercased()
            }
            throw Libgit2Error(
                code: Int32(result), klass: 0,
                message: "bad boolean config value '\(value)' for '\(canonical)'")
        }
        return parsed != 0
    }
}
