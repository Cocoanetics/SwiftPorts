import Foundation
import CGitKit
import GitKit
import CLibgit2Shim

extension GitClient {
    /// Enumerate candidates without probing them: even an existence check must
    /// follow authorization. Called inside libgit2 isolation, so search paths
    /// and tilde expansion use the same shell environment as attribute lookup.
    static func attributeAuthorizationURLs(_ repository: Repository, paths: [String]) throws -> [URL] {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                               message: "cannot reach GitKit's repository handle to authorize attributes")
        }
        var urls: [URL] = []
        var seen = Set<URL>()
        func add(_ url: URL) {
            // standardizedFileURL can consult the filesystem on Darwin.
            // Keep candidates as absolute URLs until the sandbox allows them.
            let clean = url.absoluteURL
            if seen.insert(clean).inserted { urls.append(clean) }
        }

        // Linked worktrees share info/attributes in the common git directory.
        var info = git_buf()
        defer { git_buf_dispose(&info) }
        try check(git_repository_item_path(&info, repo, GIT_REPOSITORY_ITEM_INFO))
        if let directory = info.ptr {
            add(URL(fileURLWithPath: String(cString: directory), isDirectory: true)
                .appendingPathComponent("attributes", isDirectory: false))
        }
        // Attribute lookup can fall back to .gitattributes blobs in the index.
        var index = git_buf()
        defer { git_buf_dispose(&index) }
        let indexRC = git_repository_item_path(&index, repo, GIT_REPOSITORY_ITEM_INDEX)
        if indexRC == GIT_ENOTFOUND.rawValue {
            git_error_clear()
        } else {
            try check(indexRC)
            if let path = index.ptr {
                add(URL(fileURLWithPath: String(cString: path), isDirectory: false))
            }
        }
        let root = git_repository_workdir(repo).map {
            URL(fileURLWithPath: String(cString: $0), isDirectory: true)
        }
        if let root {
            add(root.appendingPathComponent(".gitattributes", isDirectory: false))
            for path in paths {
                // git_attr_get also stats the queried path to detect directories.
                add(root.appendingPathComponent(path, isDirectory: false))
                var current = (path as NSString).deletingLastPathComponent
                while !current.isEmpty && current != "." {
                    add(root.appendingPathComponent(current, isDirectory: true)
                        .appendingPathComponent(".gitattributes", isDirectory: false))
                    let parent = (current as NSString).deletingLastPathComponent
                    if parent == current { break }
                    current = parent
                }
            }
        }

        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var configured = git_buf()
        defer { git_buf_dispose(&configured) }
        let rc = git_config_get_string_buf(&configured, config, "core.attributesfile")
        if rc == GIT_ENOTFOUND.rawValue {
            git_error_clear()
            for directory in try attributeSearchDirectories(GIT_CONFIG_LEVEL_XDG) {
                add(URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("attributes", isDirectory: false))
            }
        } else {
            try check(rc)
            if let value = configured.ptr {
                var path = String(cString: value)
                if path.hasPrefix("~/") {
                    path = Libgit2Sandboxing.shared.globalHome + "/" + path.dropFirst(2)
                }
                add(URL(fileURLWithPath: path, isDirectory: false, relativeTo: root))
            }
        }
        // libgit2's attr_setup preloads system macros even with NO_SYSTEM.
        // Authorize all search candidates before libgit2 probes any of them.
        for directory in try attributeSearchDirectories(GIT_CONFIG_LEVEL_SYSTEM) {
            add(URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("gitattributes", isDirectory: false))
        }
        return urls
    }

    private static func attributeSearchDirectories(_ level: git_config_level_t) throws -> [String] {
        var buffer = [CChar](repeating: 0, count: 65_536)
        try check(swiftports_libgit2_get_search_path(Int32(level.rawValue), &buffer, buffer.count))
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        // Match sysdir.c: a separator preceded by a backslash belongs to
        // the directory name. Libgit2 keeps that backslash in the path.
        var directories: [String] = []
        var current = ""
        let searchPath = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        for character in searchPath {
            if character == separator && current.last != "\\" {
                if !current.isEmpty { directories.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { directories.append(current) }
        return directories
    }
}
