import Foundation
import ForgeKit
import libgit2

/// Where to read/write a config entry. Mirrors `git config`'s scope flags.
public enum ConfigScope: Sendable {
    /// `.git/config` of the current repo.
    case local
    /// `~/.gitconfig` (or `$XDG_CONFIG_HOME/git/config`).
    case global
    /// `/etc/gitconfig` — read-only for our purposes.
    case system
}

extension GitClient {

    /// Read a config value (`git config --get <name>`). Returns nil
    /// when the key isn't set. With `scope == nil` reads through the
    /// merged repo config; an explicit scope opens just that file.
    public func configGet(_ name: String, scope: ConfigScope? = nil) async throws -> String? {
        try await withRepository { repo in
            var cfg: OpaquePointer?
            try check(git_repository_config(&cfg, repo))
            defer { git_config_free(cfg) }

            let resolved = try resolveConfig(cfg: cfg, scope: scope)
            defer { if resolved != cfg { git_config_free(resolved) } }

            var buf = git_buf()
            let rc = name.withCString { n in
                git_config_get_string_buf(&buf, resolved, n)
            }
            if rc == GIT_ENOTFOUND.rawValue { return nil }
            try check(rc)
            defer { git_buf_dispose(&buf) }
            return buf.ptr.map { String(cString: $0) }
        }
    }

    /// Set a config value. Defaults to writing to the local repo
    /// config, matching `git config <name> <value>`.
    public func configSet(_ name: String, _ value: String, scope: ConfigScope = .local) async throws {
        try await withRepository { repo in
            var cfg: OpaquePointer?
            try check(git_repository_config(&cfg, repo))
            defer { git_config_free(cfg) }

            let resolved = try resolveConfig(cfg: cfg, scope: scope)
            defer { if resolved != cfg { git_config_free(resolved) } }

            try check(name.withCString { n in
                value.withCString { v in
                    git_config_set_string(resolved, n, v)
                }
            })
        }
    }

    /// Remove a config entry. Returns true if removed, false if absent.
    @discardableResult
    public func configUnset(_ name: String, scope: ConfigScope = .local) async throws -> Bool {
        try await withRepository { repo in
            var cfg: OpaquePointer?
            try check(git_repository_config(&cfg, repo))
            defer { git_config_free(cfg) }

            let resolved = try resolveConfig(cfg: cfg, scope: scope)
            defer { if resolved != cfg { git_config_free(resolved) } }

            let rc = name.withCString { n in
                git_config_delete_entry(resolved, n)
            }
            if rc == GIT_ENOTFOUND.rawValue { return false }
            try check(rc)
            return true
        }
    }

    /// Walk every config entry visible to the repo (merging local +
    /// global + system layers). Returns `(name, value)` pairs in
    /// libgit2's iteration order — matches `git config --list`.
    public func configList() async throws -> [(name: String, value: String)] {
        try await withRepository { repo in
            var cfg: OpaquePointer?
            try check(git_repository_config(&cfg, repo))
            defer { git_config_free(cfg) }

            var iter: UnsafeMutablePointer<git_config_iterator>?
            try check(git_config_iterator_new(&iter, cfg))
            defer { git_config_iterator_free(iter) }

            var entries: [(String, String)] = []
            while true {
                var entry: UnsafeMutablePointer<git_config_entry>?
                let rc = git_config_next(&entry, iter)
                if rc == GIT_ITEROVER.rawValue { break }
                try check(rc)
                if let e = entry?.pointee,
                   let nameCStr = e.name, let valueCStr = e.value {
                    entries.append((String(cString: nameCStr),
                                    String(cString: valueCStr)))
                }
            }
            return entries
        }
    }

    /// Resolve a `ConfigScope` to a concrete `git_config` handle.
    /// `nil` returns the merged repo config (caller already owns it).
    private func resolveConfig(
        cfg: OpaquePointer?, scope: ConfigScope?
    ) throws -> OpaquePointer? {
        switch scope {
        case .none, .some(.local):
            // For .local we want the local file specifically; libgit2
            // exposes that via git_config_open_level. For nil we use
            // the merged config the caller already has.
            if scope == nil { return cfg }
            var local: OpaquePointer?
            try check(git_config_open_level(&local, cfg, GIT_CONFIG_LEVEL_LOCAL))
            return local

        case .some(.global):
            var global: OpaquePointer?
            try check(git_config_open_global(&global, cfg))
            return global

        case .some(.system):
            var system: OpaquePointer?
            try check(git_config_open_level(&system, cfg, GIT_CONFIG_LEVEL_SYSTEM))
            return system
        }
    }
}
