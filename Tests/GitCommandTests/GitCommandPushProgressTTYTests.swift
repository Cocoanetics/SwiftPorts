// `git push` shows its meter as git's `transport_set_verbosity` decides
// (issue #264): `--progress` / `--no-progress` (last wins), else not with
// `-q`, else only on a terminal. `-q` also drops `To`, ref lines and
// `remote:` text. Checked against system git 2.54 with stderr redirected:
// with neither flag it prints neither the `\r` updates nor the done lines.
#if os(macOS) || os(Linux)
import ArgumentParser
import Foundation
import Testing
@testable import GitCommand
@testable import SwiftGit

@Suite("git push progress on and off a terminal")
struct GitCommandPushProgressTTYTests {
    /// The sink's writes, in order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        var texts: [String] { lock.withLock { written } }
        func append(_ text: String) { lock.withLock { written.append(text) } }
    }

    private static let update = "Writing objects: 50% (2/4), 12 bytes\r"
    private static let done = "Writing objects: 100% (4/4), 24 bytes, done.\n"
    private static let remote = "remote: hook\n"
    private static let header = "To /srv/repo\n"
    private static let ref = "   6bfcd70..8124fb4  main -> main\n"
    private static let recorded = [update, done, remote, header, ref]

    /// `git push <args>` parsed as the CLI parses it.
    private func push(_ args: [String]) throws -> Push {
        let parsed = try GitCommand.parseAsRoot(["push"] + args)
        return try #require(parsed as? Push)
    }

    /// What `git push <args>` writes of the recorded callback strings.
    private func written(_ args: [String], terminal: Bool) throws -> [String] {
        let command = try push(args)
        let policy = PushProgressSink(
            reportProgress: command.progress, quiet: command.quiet, terminal: terminal)
        let records = Recorder()
        let sink = policy.sink(writing: records.append)
        Self.recorded.forEach(sink)
        return records.texts
    }

    @Test func unsetOffATerminalDropsTheMeter() throws {
        #expect(try written(["origin"], terminal: false) == [Self.remote, Self.header, Self.ref])
    }

    @Test func unsetOnATerminalKeepsTheMeter() throws {
        #expect(try written(["origin"], terminal: true) == Self.recorded)
    }

    @Test func noProgressOnATerminalDropsTheMeter() throws {
        #expect(try written(["--no-progress", "origin"], terminal: true)
            == [Self.remote, Self.header, Self.ref])
    }

    @Test func quietOnATerminalDropsEverything() throws {
        #expect(try written(["-q", "origin"], terminal: true).isEmpty)
    }

    @Test func quietWithProgressKeepsOnlyTheMeter() throws {
        #expect(try written(["-q", "--progress", "origin"], terminal: false) == [Self.update, Self.done])
    }

    @Test func lastProgressFlagWins() throws {
        #expect(try push(["--progress", "--no-progress", "origin"]).progress == false)
        #expect(try push(["--no-progress", "--progress", "origin"]).progress == true)
        #expect(try push(["origin"]).progress == nil)
        #expect(try written(["--progress", "--no-progress", "origin"], terminal: true)
            == [Self.remote, Self.header, Self.ref])
        #expect(try written(["--no-progress", "--progress", "origin"], terminal: false) == Self.recorded)
    }
}
#endif
