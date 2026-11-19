import Foundation
import ShellKit
import SwiftGit

/// Options of `commands/command_track.go`; untrack shares the same pattern escaping.
public struct TrackOptions: Sendable {
    public var lockable = false
    public var notLockable = false
    public var dryRun = false
    public var verbose = false
    public var json = false
    public var noExcluded = false
    public var filename = false
    public var noModifyAttrs = false

    public init() {}

    public func track(_ patterns: [String], client: SwiftGit.GitClient) async throws -> LFSCommandResult {
        do {
            let repo = try await LFSRepository.open(client, workTree: true)
            let noInstallHooks = ["true", "1", "on", "yes", "t"]
                .contains((Shell.env("GIT_LFS_TRACK_NO_INSTALL_HOOKS") ?? "").lowercased())
            if !noInstallHooks {
                for hook in Hook.loadHooks(directory: try await repo.hookDirectory(client)) {
                    try? await hook.install()
                }
            }
            var reader = Attributes()
            let known = try await reader.paths(repo, client: client, includeExternal: patterns.isEmpty)
            if patterns.isEmpty { return listing(known) }
            if json { return LFSCommandResult(stderr: "--json option can't be combined with arguments\n", status: 2) }
            return try await edit(patterns, known: known, repo: repo, client: client)
        } catch let error as LFSFailure {
            return error.result
        }
    }

    public func untrack(_ patterns: [String], client: SwiftGit.GitClient) async throws -> LFSCommandResult {
        do {
            let repo = try await LFSRepository.open(client, workTree: true)
            for hook in Hook.loadHooks(directory: try await repo.hookDirectory(client)) { try? await hook.install() }
            if patterns.isEmpty { return LFSCommandResult(stdout: "git lfs untrack <path> [path]*\n") }
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            try await Shell.authorize(path)
            guard let data = try? Data(contentsOf: path) else { return LFSCommandResult() }
            var result = LFSCommandResult()
            var output = ""
            for line in Self.lines(String(decoding: data, as: UTF8.self)) {
                let pattern = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                if line.contains("filter=lfs") && patterns.contains(where: {
                    Self.trimCurrent(pattern) == Self.escape(Self.trimCurrent($0))
                }) {
                    result.stdout += "Untracking \(Self.unescape(pattern).goQuoted)\n"
                } else {
                    output += line + "\n"
                }
            }
            do { try output.write(to: path, atomically: false, encoding: .utf8) }
            catch { result.stdout += "Error opening '.gitattributes' for writing\n" }
            return result
        } catch let error as LFSFailure {
            return error.result
        }
    }

    static func trimCurrent(_ pattern: String) -> String {
        pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
    }

    static func escape(_ pattern: String, literal: Bool = false) -> String {
        #if os(Windows)
        var escaped = pattern.replacingOccurrences(of: "\\", with: "/")
        #else
        var escaped = pattern.replacingOccurrences(of: "\\", with: "\\\\")
        #endif
        if literal {
            for character in ["*", "[", "]", "?"] {
                escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
            }
        }
        return escaped.replacingOccurrences(of: " ", with: "[[:space:]]")
            .replacingOccurrences(of: "#", with: "\\#")
    }

    static func unescape(_ pattern: String) -> String {
        var value = pattern.replacingOccurrences(of: "[[:space:]]", with: " ")
            .replacingOccurrences(of: "\\#", with: "#")
        #if !os(Windows)
        value = value.replacingOccurrences(of: "\\\\", with: "\\")
        #endif
        return value
    }

    static func lines(_ text: String) -> [String] {
        // Match Go's bufio.Scanner: split LF bytes, including inside CRLF.
        // A CR is dropped only when it belongs to a newline. Foundation's
        // string separator handling differs across platforms here.
        let terminated = text.utf8.last == 0x0A
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if terminated, lines.last == "" { lines.removeLast() }
        return lines.enumerated().map { index, line in
            let dropCarriage = line.hasSuffix("\r") && (terminated || index < lines.count - 1)
            return dropCarriage ? String(line.dropLast()) : line
        }
    }

    /// git-lfs `lineEndingSplitter`: CRLF only when it outnumbers LF.
    /// A file with no newline (the unterminated tail is not counted) yields "".
    static func attributeLineEnding(_ text: String) -> String {
        var lineFeeds = 0
        var carriageReturns = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous == 0x0D { carriageReturns += 1 } else { lineFeeds += 1 }
            }
            previous = byte
        }
        if carriageReturns > lineFeeds { return "\r\n" }
        if lineFeeds == 0 { return "" }
        return "\n"
    }
}
