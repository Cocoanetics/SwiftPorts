import Foundation
import NIOSSH
import ShellKit

/// A parsed set of `known_hosts` files, supporting both plain and hashed (`|1|`) entries.
///
/// Mutation is split across a sync/async boundary on purpose: `NIOSSHClientServerAuthenticationDelegate
/// .validateHostKey(hostKey:validationCompletePromise:)` is a synchronous callback, so recording a
/// newly-trusted host key during that callback can only update the in-memory copy
/// (`recordNewHost`); persisting the line to disk (`appendToFile`) is a separate, async operation
/// the caller fires off afterward — matching `add_host_to_hostfile()` in `hostfile.c`, except that
/// in this port the disk write isn't guaranteed to complete before the connection proceeds.
public struct KnownHostsStore: Sendable {
    public private(set) var entries: [KnownHostsEntry]

    public init(entries: [KnownHostsEntry] = []) {
        self.entries = entries
    }

    /// Parses in-memory `known_hosts` text (for tests/fixtures). Malformed lines are skipped,
    /// matching `load_hostkeys()`'s tolerance of bad lines in `hostfile.c`. `@cert-authority` /
    /// `@revoked` marker lines are out of scope for this port's subset and are skipped rather
    /// than mis-trusting or mis-revoking a key.
    public static func parse(_ contents: String, source: String) -> KnownHostsStore {
        var entries: [KnownHostsEntry] = []

        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.first != "#", trimmed.first != "@" else {
                continue
            }

            let fields = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count >= 3 else {
                continue
            }

            let hostField = String(fields[0])
            let algorithm = String(fields[1])
            guard let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: "\(algorithm) \(fields[2])") else {
                continue
            }

            entries.append(
                KnownHostsEntry(
                    hostField: hostField,
                    algorithm: algorithm,
                    publicKey: publicKey,
                    comment: fields.count > 3 ? String(fields[3]) : nil,
                    sourceDescription: source,
                    lineNumber: lineNumber
                )
            )
        }

        return KnownHostsStore(entries: entries)
    }

    /// Loads every path in `paths` (tilde-expanded), in order. A missing file is skipped, matching
    /// `load_hostkeys()`'s tolerance of an absent `known_hosts`.
    public static func load(paths: [String]) async throws -> KnownHostsStore {
        var entries: [KnownHostsEntry] = []

        for path in paths {
            let url = Shell.resolve(SSHPath.expandingTilde(path))
            try await Shell.authorize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let contents = try String(contentsOf: url, encoding: .utf8)
            entries.append(contentsOf: Self.parse(contents, source: path).entries)
        }

        return KnownHostsStore(entries: entries)
    }

    public func matchingEntries(forHost host: String) -> [KnownHostsEntry] {
        self.entries.filter { $0.matches(host: host) }
    }

    /// Records a newly-trusted host key in memory only — see the type-level note on the sync/async
    /// split. `hashed` selects the hashed (`|1|`) or plain host field.
    @discardableResult
    public mutating func recordNewHost(_ host: String, publicKey: NIOSSHPublicKey, hashed: Bool) -> KnownHostsEntry {
        let entry = KnownHostsEntry(
            hostField: hashed ? HostKeyHashing.hash(host: host) : host,
            algorithm: SSHPublicKeyDescribing.algorithmIdentifier(for: publicKey),
            publicKey: publicKey,
            comment: nil,
            sourceDescription: "<memory>",
            lineNumber: self.entries.count + 1
        )
        self.entries.append(entry)
        return entry
    }

    /// Appends `entry` to `path` (tilde-expanded), creating the file if needed. Mirrors
    /// `add_host_to_hostfile()` in `hostfile.c`.
    public static func appendToFile(_ entry: KnownHostsEntry, path: String) async throws {
        let url = Shell.resolve(SSHPath.expandingTilde(path))
        try await Shell.authorize(url)

        let line = Data("\(entry.hostField) \(String(openSSHPublicKey: entry.publicKey))\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try line.write(to: url)
        }
    }
}
