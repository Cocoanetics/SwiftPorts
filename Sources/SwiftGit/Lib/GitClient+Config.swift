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

    /// Every value of a multi-valued key (`git config --get-all <name>`),
    /// in the order git reads them: system, global, then the
    /// repository's own config, each file top to bottom. A key without
    /// a value (`[remote "origin"] push`) has none to give.
    public func configGetAll(_ name: String) async throws -> [String] {
        try await withRepository { _ in try Self.configValues(name, in: workingDirectory) }
    }

    /// Every remote's `remote.<name>.push` values, in the order git reads
    /// them: lowest config level first, each file top to bottom.
    public func allRemotePushRefspecs() async throws -> [String] {
        try await withRepository { _ in
            try Self.configValues(matching: "^remote\\..*\\.push$", in: workingDirectory)
        }
    }

    /// `name`'s values, lowest config level first. libgit2 iterates its
    /// levels highest first, git reads them the other way round.
    static func configValues(_ name: String, in directory: URL) throws -> [String] {
        try configValues(in: directory) { config, iterator in
            git_config_multivar_iterator_new(&iterator, config, name, nil)
        }
    }

    /// The values of every key matching `regex`, in git's order.
    static func configValues(matching regex: String, in directory: URL) throws -> [String] {
        try configValues(in: directory) { config, iterator in
            git_config_iterator_glob_new(&iterator, config, regex)
        }
    }

    private static func configValues(
        in directory: URL,
        iterate: (OpaquePointer?, inout UnsafeMutablePointer<git_config_iterator>?) -> CInt
    ) throws -> [String] {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        defer {
            git_config_iterator_free(iterator)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try check(git_repository_config_snapshot(&config, repo))
        try check(iterate(config, &iterator))
        var values: [(level: Int, value: String)] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee, let value = entry.value else { continue }
            values.append((Int(entry.level.rawValue), String(cString: value)))
        }
        // A stable sort keeps each level's values in file order.
        return values.enumerated()
            .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element.value)
    }

    /// The first `remote.<name>.push` written without a value
    /// (`[remote "origin"] push`), which git refuses to run with, as git
    /// names it: the key, the file (relative to the work tree's top when
    /// in it, as git reads it from there) and the line.
    public func valuelessRemotePush() async throws -> (key: String, file: String, line: Int)? {
        try await withRepository { _ in try Self.valuelessRemotePush(in: workingDirectory) }
    }

    static func valuelessRemotePush(in directory: URL) throws -> (key: String, file: String, line: Int)? {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        defer {
            git_config_iterator_free(iterator)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try check(git_repository_config_snapshot(&config, repo))
        try check(git_config_iterator_glob_new(&iterator, config, "^remote\\..*\\.push$"))
        var found: [(key: String, path: String, level: Int)] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee, entry.value == nil,
                  let name = entry.name, let origin = entry.origin_path
            else { continue }
            found.append((String(cString: name), String(cString: origin), Int(entry.level.rawValue)))
        }
        // git reads the files lowest level first and stops at the first.
        guard let first = found.min(by: { $0.level < $1.level }) else { return nil }
        let line = valuelessLine(of: first.key, in: URL(fileURLWithPath: first.path)) ?? 0
        // Relative to where git reads it from: the work tree's top, or a
        // bare repository's own directory.
        var file = first.path
        let base = (git_repository_workdir(repo) ?? git_repository_path(repo)).map { String(cString: $0) }
        if let base, file.hasPrefix(base) {
            file = String(file.dropFirst(base.count))
        }
        return (first.key, file, line)
    }

    /// What's between a header line's `[` and its `]`, a `]` inside the
    /// quoted subsection (`[remote "orig]in"]`) not counting.
    private static func sectionHeader(_ line: String) -> Substring {
        let body = line.dropFirst()
        var quoted = false
        var escaped = false
        for index in body.indices {
            let character = body[index]
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "]", !quoted {
                return body[..<index]
            }
        }
        return body
    }

    /// A quoted subsection as git reads it: `"orig\"in"` is `orig"in`,
    /// a backslash taking the next character as it is.
    private static func decodedSubsection(_ quoted: Substring) -> String {
        var body = quoted.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))[...]
        if body.hasPrefix("\"") { body = body.dropFirst() }
        // The closing quote ends the header, whatever comes before it.
        if body.hasSuffix("\"") { body = body.dropLast() }
        var decoded = ""
        var escaped = false
        for character in body {
            if escaped {
                decoded.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                decoded.append(character)
            }
        }
        return decoded
    }

    /// The line of `file` where `key` (`remote.origin.push`) is written
    /// without a value, counting from 1.
    private static func valuelessLine(of key: String, in file: URL) -> Int? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let subsection = parts.dropFirst().dropLast().joined(separator: ".")
        let variable = String(parts.last!)
        var inSection = false
        // Swift reads `\r\n` as one Character: split on any newline.
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            // A CRLF file's lines end in `\r` as well.
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                // `[remote "origin"]`: the section ignores case, the
                // subsection doesn't.
                let header = Self.sectionHeader(line)
                // Spaces and tabs both separate a section from its
                // subsection.
                let pieces = header.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                if pieces.count == 2 {
                    inSection = pieces[0].lowercased() == String(parts[0])
                        && decodedSubsection(pieces[1]) == subsection
                } else if let dot = header.firstIndex(of: ".") {
                    // The older `[remote.origin]`, which git reads with
                    // the subsection lowercased.
                    inSection = header[..<dot].lowercased() == String(parts[0])
                        && header[header.index(after: dot)...].lowercased() == subsection.lowercased()
                } else {
                    inSection = false
                }
                continue
            }
            if inSection, !line.contains("="), line.lowercased() == variable {
                return index + 1
            }
        }
        return nil
    }

    /// Whether git takes `refspec` as a push refspec (refspec.c's
    /// `parse_refspec`): `:` (matching), else a source and an optional
    /// destination, both patterns or neither. The source may be empty
    /// (a deletion), an object ID or any revision, but must be a ref
    /// name when it's a pattern or there's no destination; a destination
    /// must be a ref name. A negative refspec (`^refs/heads/wip`) is a
    /// ref name or pattern alone: not forced, not empty, without a
    /// destination, not an object ID.
    public static func isValidPushRefspec(_ refspec: String) -> Bool {
        var body = Substring(refspec)
        let forced = body.hasPrefix("+")
        if forced { body = body.dropFirst() }
        if body.hasPrefix("^") {
            let name = body.dropFirst()
            guard !forced, !name.isEmpty, !name.contains(":"),
                  !(name.count == 40 && name.utf8.allSatisfy({ isASCIIHex($0) }))
            else { return false }
            return isRefName(name, pattern: name.contains("*"))
        }
        if body == ":" { return true }
        let colon = body.lastIndex(of: ":")
        let source = colon.map { body[..<$0] } ?? body
        let destination = colon.map { body[body.index(after: $0)...] }
        let globDestination = destination?.contains("*") ?? false
        let globSource = source.contains("*")
        if globSource, destination != nil, !globDestination { return false }
        if !globSource, globDestination { return false }
        if globSource, !isRefName(source, pattern: true) { return false }
        guard let destination else { return isRefName(source, pattern: globSource) }
        return !destination.isEmpty && isRefName(destination, pattern: globSource)
    }

    private static func isASCIIHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte | 0x20)
    }

    /// git's check_refname_format with one-level names allowed, and a
    /// `*` with `pattern`. libgit2's ALLOW_ONELEVEL takes only all-caps
    /// names (`HEAD`), so the name is checked under `refs/`, which keeps
    /// every rule for its components.
    private static func isRefName(_ name: Substring, pattern: Bool) -> Bool {
        Libgit2.ensureInitialized()
        let candidate = name.hasPrefix("refs/") ? String(name) : "refs/\(name)"
        let flags = pattern ? UInt32(GIT_REFERENCE_FORMAT_REFSPEC_PATTERN.rawValue) : 0
        var buffer = [CChar](repeating: 0, count: candidate.utf8.count + 1)
        guard git_reference_normalize_name(&buffer, buffer.count, candidate, flags) == 0 else {
            return false
        }
        return String(cString: buffer) == candidate
    }

    /// A boolean config value as git reads one (`true`/`yes`/`on`, any
    /// nonzero integer, a key without a value), or `nil` when unset.
    /// Anything else throws git's "bad boolean config value".
    public func configBool(_ name: String) async throws -> Bool? {
        try await withRepository { _ in
            try Self.configEntry(name, in: workingDirectory).map { try Self.parseGitBool($0, key: name) }
        }
    }

    /// The config entry `name` as written, `nil` when it isn't set:
    /// `.some(nil)` for a key without a value (`[push] autoSetupRemote`),
    /// which ``configGet(_:scope:)`` reads as empty. GitKit keeps its
    /// repository handle to itself, so this opens its own.
    static func configEntry(_ name: String, in directory: URL) throws -> String?? {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var entry: UnsafeMutablePointer<git_config_entry>?
        defer {
            git_config_entry_free(entry)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try check(git_repository_config_snapshot(&config, repo))
        let result = git_config_get_entry(&entry, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        try check(result)
        return .some(entry?.pointee.value.map { String(cString: $0) })
    }

    /// Throws libgit2's error for a call that failed with `result`.
    static func check(_ result: CInt) throws {
        guard result < 0 else { return }
        let last = git_error_last()
        throw Libgit2Error(
            code: result, klass: last?.pointee.klass ?? 0,
            message: last?.pointee.message.map { String(cString: $0) } ?? "unknown error")
    }

    /// git's boolean parsing (`git_config_parse_bool`) and its error,
    /// which names the key the way git spells it (section and variable
    /// lowercased: `push.autosetupremote`). A key without a value is
    /// true; an empty value is false.
    /// An environment variable read as git reads a boolean one
    /// (`git_env_bool`): the config rules, with git's error for a value
    /// that is none (`GIT_ADVICE=bogus`).
    public static func parseGitBoolEnvironment(_ value: String, name: String) throws -> Bool {
        var parsed: CInt = 0
        let result = value.withCString { git_config_parse_bool(&parsed, $0) }
        guard result == 0 else {
            throw Libgit2Error(
                code: Int32(result), klass: 0,
                message: "bad boolean environment value '\(value)' for '\(name)'")
        }
        return parsed != 0
    }

    static func parseGitBool(_ value: String?, key: String) throws -> Bool {
        guard let value else { return true }
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
