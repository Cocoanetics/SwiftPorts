import Foundation
import CGitKit
import GitKit
import ShellKit

extension GitClient {
    /// Evaluate the `filter` git attribute for each repository-relative path,
    /// returning those entries whose `filter` attribute has a string value
    /// (for example `"lfs"`).
    public func filterAttribute(for paths: [String]) async throws -> [String: String] {
        var seen = Set<String>()
        let unique = paths.filter {
            !$0.isEmpty && !$0.hasPrefix("/") && !$0.hasPrefix("\\")
                && !$0.split(separator: "/").contains("..") && seen.insert($0).inserted
        }
        guard !unique.isEmpty else { return [:] }
        let attrURLs = try await withFilterMetadataRepository { repository in
            try Self.attributeAuthorizationURLs(repository, paths: unique)
        }
        for url in attrURLs {
            try await Shell.authorize(url)
        }
        let noSystem = Shell.env("GIT_ATTR_NOSYSTEM") == "1"
        return try await withFilterMetadataRepository { repository in
            try Self.readFilterAttributes(repository, paths: unique, noSystem: noSystem)
        }
    }

    private static func readFilterAttributes(
        _ repository: Repository, paths: [String], noSystem: Bool
    ) throws -> [String: String] {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                message: "cannot reach GitKit's repository handle to evaluate attributes")
        }
        var flags = UInt32(GIT_ATTR_CHECK_FILE_THEN_INDEX)
        if noSystem { flags |= UInt32(GIT_ATTR_CHECK_NO_SYSTEM) }
        var result: [String: String] = [:]
        for path in paths {
            var value: UnsafePointer<CChar>?
            let rc = path.withCString { git_attr_get(&value, repo, flags, $0, "filter") }
            guard rc == 0 else {
                git_error_clear()
                continue
            }
            if let value, git_attr_value(value) == GIT_ATTR_VALUE_STRING {
                result[path] = String(cString: value)
            }
        }
        return result
    }
}
