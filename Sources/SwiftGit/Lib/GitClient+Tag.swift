import Foundation
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` tag operations
// (`GitKit/Repository+Tag.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// List tags whose name matches `pattern` (a fnmatch glob); pass
    /// `nil` for all tags.
    public func tagList(pattern: String? = nil) async throws -> [String] {
        try await withRepository { try $0.tagList(pattern: pattern) }
    }

    /// Detailed listing with message + target sha, for `git tag -n`
    /// style formatting.
    public func tagDetails(pattern: String? = nil) async throws -> [TagEntry] {
        try await withRepository { try $0.tagDetails(pattern: pattern) }
    }

    /// Create a lightweight tag pointing at `target` (default HEAD).
    @discardableResult
    public func tagCreate(
        name: String, target: String = "HEAD", force: Bool = false
    ) async throws -> String {
        try await withRepository {
            try $0.tagCreate(name: name, target: target, force: force)
        }
    }

    /// Create an annotated tag; `tagger` defaults to the committer-role
    /// signature resolved through env vars + config.
    @discardableResult
    public func tagCreateAnnotated(
        name: String, target: String = "HEAD",
        message: String, tagger: GitSignature? = nil,
        force: Bool = false
    ) async throws -> String {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.tagCreateAnnotated(
                name: name, target: target, message: message,
                tagger: tagger.core, force: force, env: env)
        }
    }

    /// Delete a tag. Returns the SHA of what the tag was pointing at.
    @discardableResult
    public func tagDelete(name: String) async throws -> String {
        try await withRepository { try $0.tagDelete(name: name) }
    }

    /// True when a tag with `name` already exists.
    public func tagExists(_ name: String) async throws -> Bool {
        try await withRepository { try $0.tagExists(name) }
    }
}
