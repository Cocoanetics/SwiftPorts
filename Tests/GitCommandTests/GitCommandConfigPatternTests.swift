// `git config --get` / `--unset` with a value pattern, the path errors git
// words, and the config syntax git refuses where libgit2 doesn't (#137).
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config value patterns and strictness")
struct GitCommandConfigPatternTests: ConfigTestHelpers {

    /// `git init -q` with the system git.
    private func initRepository(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q"]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
    }

    @Test("--get with a value pattern shows the last value it admits, a `!` negating it, --show-origin included")
    func getWithPattern() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        try "[a]\n\tb = 1\n\tb = 2\n\tb = hello\n".write(to: file, atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        #expect(try await run(["--get", "a.b", "hel+"]).stdout == "hello\n")
        #expect(try await run(["--get", "a.b", "^[0-9]"]).stdout == "2\n")
        #expect(try await run(["--get", "a.b", "!^[0-9]"]).stdout == "hello\n")
        #expect(try await run(["--get", "a.b", "!hel"]).stdout == "2\n")
        for args in [["--get", "a.b", "zzz"], ["--get", "a.b", "!."], ["--get", "x.y", "zzz"]] {
            let none = try await run(args)
            #expect(none.status == 1 && none.stdout.isEmpty && none.stderr.isEmpty, "\(args)")
        }
        #expect(try await run(["--show-origin", "--get", "a.b", "^[0-9]"]).stdout == "file:\(file.path)\t2\n")
        #expect(try await run(["--show-origin", "--get", "a.b", "zzz"]).status == 1)
        // An unscoped read sees the global file as well.
        let unscoped = try await git(["config", "--get", "a.b", "hel+"], root: root, home: home, work: work)
        #expect(unscoped.stdout == "hello\n")
    }

    @Test("a pattern git can't compile is `invalid pattern`, status 6: after the key, before any read")
    func invalidPattern() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        let contents = "[a]\n\tb = hello\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        func run(_ args: [String], environment: [String: String] = [:]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work, environment: environment)
        }

        for args in [["--get", "a.b", "["], ["--get", "x.y", "["], ["--get", "a.b", "!["],
                     ["--unset", "a.b", "["], ["--unset", "x.y", "["], ["--unset", "a.b", "!["]] {
            let result = try await run(args)
            #expect(result.stderr == "error: invalid pattern: [\n" && result.status == 6, "\(args)")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)

        // The key comes first.
        let get = try await run(["--get", "nodot", "["])
        #expect(get.stderr == "error: key does not contain a section: nodot\n" && get.status == 1)
        let unset = try await run(["--unset", "nodot", "["])
        #expect(unset.stderr == "error: key does not contain a section: nodot\n" && unset.status == 2)

        // A file that isn't there is nothing to unset before the pattern is
        // looked at; a get compiles it regardless.
        let missing = ["GIT_CONFIG_GLOBAL": root.appendingPathComponent("none.cfg").path]
        let nothing = try await run(["--unset", "a.b", "["], environment: missing)
        #expect(nothing.status == 5 && nothing.stderr.isEmpty)
        #expect(try await run(["--get", "a.b", "["], environment: missing).status == 6)
    }

    @Test("--unset with a value pattern removes the one value it admits; several are a warning, none is status 5")
    func unsetWithPattern() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        let contents = "[a]\n\tb = 1\n\tb = 2\n\tb = hello\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        let several = try await run(["--unset", "a.b", "^[0-9]"])
        #expect(several.stderr == "warning: a.b has multiple values\n" && several.status == 5)
        let none = try await run(["--unset", "a.b", "zzz"])
        #expect(none.status == 5 && none.stderr.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)

        #expect(try await run(["--unset", "a.b", "hel"]).status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[a]\n\tb = 1\n\tb = 2\n")
        #expect(try await run(["--unset", "a.b", "!^1"]).status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[a]\n\tb = 1\n")
        // The last value of a section takes its header with it.
        #expect(try await run(["--unset", "a.b"]).status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
        #expect(!FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

    @Test("a key without a value matches no pattern of its own, only a negated one; a get reads it as empty")
    func valuelessKey() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        try "[a]\n\tb\n\tc = x\n".write(to: file, atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        let empty = try await run(["--get", "a.b", "^$"])
        #expect(empty.stdout == "\n" && empty.status == 0)
        #expect(try await run(["--get", "a.b", "x"]).status == 1)
        #expect(try await run(["--unset", "a.b", "^$"]).status == 5)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[a]\n\tb\n\tc = x\n")
        #expect(try await run(["--unset", "a.b", "!zzz"]).status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[a]\n\tc = x\n")
    }

    @Test("--get and --unset take a name and at most a pattern; a key git can't parse is its diagnostic")
    func argumentsAndKeys() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        let contents = "[a]\n\tb = hello\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        for args in [["--get", "a.b", "x", "y"], ["--unset", "a.b", "x", "y"], ["--get"], ["--unset"]] {
            let result = try await run(args)
            #expect(result.stderr == "error: wrong number of arguments, should be from 1 to 2\n", "\(args)")
            #expect(result.status == 129, "\(args)")
        }
        let keys: [(args: [String], reason: String, status: Int32)] = [
            (["--get", "nodot"], "key does not contain a section: nodot", 1),
            (["--get", "a."], "key does not contain variable name: a.", 1),
            (["--get", "a.1b"], "invalid key: a.1b", 1),
            (["--unset", "nodot"], "key does not contain a section: nodot", 2),
            (["--unset", ".b"], "key does not contain a section: .b", 2),
            (["--unset", "a."], "key does not contain variable name: a.", 2),
            (["--unset", "a.1b"], "invalid key: a.1b", 1),
            (["--unset", "a.b_c"], "invalid key: a.b_c", 1)
        ]
        for (args, reason, status) in keys {
            let result = try await run(args)
            #expect(result.stderr == "error: \(reason)\n" && result.status == status, "\(args)")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)
    }

    @Test("an unset rewrites the file as git does: the line goes, a section left empty too unless a comment is by it")
    func unsetFormatting() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        let cases: [(before: String, args: [String], after: String)] = [
            ("[a]\n\tb = hello\n[c]\n\td = 1\n", ["a.b"], "[c]\n\td = 1\n"),
            ("[a]\n\tb = hello\n", ["a.b"], ""),
            ("# top\n[a]\n\tb = hello\n", ["a.b"], "# top\n[a]\n"),
            ("[a]\n\t# about b\n\tb = hello\n", ["a.b"], "[a]\n\t# about b\n"),
            ("[a]\n\tb = hello # trailing\n", ["a.b"], ""),
            ("[a] b = hello\n", ["a.b"], ""),
            ("[a]\n\tb = hello\n\tc = x\n", ["a.b"], "[a]\n\tc = x\n"),
            ("[a]\n\tc = x\n\tb = hello", ["a.b"], "[a]\n\tc = x\n"),
            ("[a]\r\n\tb = hello\r\n\tc = x\r\n", ["a.b"], "[a]\r\n\tc = x\r\n"),
            ("[a]\n\tb = hel\\\n\tlo\n\tc = x\n", ["a.b"], "[a]\n\tc = x\n"),
            ("[a]\n\tb = 1\n[a]\n\tb = 2\n", ["a.b", "2"], "[a]\n\tb = 1\n"),
            ("[A \"Sub\"]\n\tB = 1\n[a \"sub\"]\n\tb = 2\n", ["a.Sub.b"], "[a \"sub\"]\n\tb = 2\n")
        ]
        for (before, args, after) in cases {
            try before.write(to: file, atomically: true, encoding: .utf8)
            let result = try await run(["--unset"] + args)
            #expect(result.status == 0 && result.stderr.isEmpty, "\(args) in \(before.debugDescription)")
            #expect(try String(contentsOf: file, encoding: .utf8) == after, "\(args) in \(before.debugDescription)")
        }

        // The old `[a.Sub]` spelling reads lowercased, a quoted subsection as written.
        try "[A \"Sub\"]\n\tB = 1\n[a \"sub\"]\n\tb = 2\n[a.Sub]\n\tb = 3\n".write(
            to: file, atomically: true, encoding: .utf8)
        #expect(try await run(["--unset", "a.Sub.b", "2"]).status == 5)
        let several = try await run(["--unset", "a.sub.b"])
        #expect(several.stderr == "warning: a.sub.b has multiple values\n" && several.status == 5)

        // The file keeps its mode.
        try "[a]\n\tb = 1\n\tc = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        #expect(try await run(["--unset", "a.b"]).status == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test("inside a repository the unset works on .git/config, named as git names it, from a subdirectory too")
    func localScope() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepository(at: work)
        let config = work.appendingPathComponent(".git/config")
        try "[x]\n\ty = z\n".write(to: config, atomically: true, encoding: .utf8)
        let sub = work.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        // The lock comes first, for a set as for an unset.
        let lock = work.appendingPathComponent(".git/config.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        for (args, directory) in [(["--unset", "x.y"], work), (["--local", "--unset", "x.y"], work),
                                  (["--unset", "x.y"], sub), (["x.y", "w"], work)] {
            let result = try await git(["config"] + args, root: root, home: home, work: directory)
            #expect(result.stderr == "error: could not lock config file .git/config: File exists\n", "\(args)")
            #expect(result.status == 255, "\(args)")
        }
        try FileManager.default.removeItem(at: lock)
        #expect(try await git(["config", "--unset", "x.y", "nomatch"], root: root, home: home, work: sub).status == 5)
        #expect(try await git(["config", "--unset", "x.y", "z"], root: root, home: home, work: sub).status == 0)
        #expect(try String(contentsOf: config, encoding: .utf8) == "")
    }

    @Test("a config file that is a symlink is edited where it points, the link kept, and locked there")
    func symlinkedConfig() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = home.appendingPathComponent("real.cfg")
        try "[a]\n\tb = hello\n\tc = x\n".write(to: real, atomically: true, encoding: .utf8)
        let link = home.appendingPathComponent(".gitconfig")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.cfg")
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        // A lock held by the target is the link's too.
        let lock = home.appendingPathComponent("real.cfg.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        let held = try await run(["--unset", "a.b"])
        #expect(held.stderr == "error: could not lock config file \(link.path): File exists\n" && held.status == 255)
        try FileManager.default.removeItem(at: lock)

        #expect(try await run(["--unset", "a.b"]).status == 0)
        #expect(try String(contentsOf: real, encoding: .utf8) == "[a]\n\tc = x\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real.cfg")
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        #expect(!FileManager.default.fileExists(atPath: link.path + ".lock"))
    }

    @Test("a config path under a regular file is `Not a directory`, to lock and to read")
    func notADirectory() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("file/config")
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work,
                          environment: ["GIT_CONFIG_GLOBAL": target.path])
        }

        for args in [["x.y", "z"], ["--unset", "x.y"], ["--unset", "x.y", "zzz"]] {
            let result = try await run(args)
            #expect(result.stderr == "error: could not lock config file \(target.path): Not a directory\n", "\(args)")
            #expect(result.status == 255, "\(args)")
        }
        for args in [["--get", "x.y"], ["--get", "x.y", "zzz"]] {
            let result = try await run(args)
            #expect(result.status == 1 && result.stderr.isEmpty, "\(args)")
        }
        let list = try await run(["--list"])
        #expect(list.stderr == "fatal: unable to read config file '\(target.path)': Not a directory\n")
        #expect(list.status == 128)
    }

    @Test("what git refuses to read is refused with git's line, where libgit2 would read it")
    func parserStrictness() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        let refused: [(contents: String, line: Int)] = [
            ("[a]\n\tb = \"unterminated\n", 2),
            ("[a]\n\tb = \"c\n", 2),
            ("[a]\n\tb = c\\q\n", 2),
            ("[a]\n\t1b = c\n", 2),
            ("[a]\n-b = c\n", 2),
            ("[a]\n\tb = c\\;d\n", 2),
            ("[a]\n\tb = c\"\n", 2),
            ("[a]\n\tb = c\n\n\n\tb = \"\n", 5),
            ("[a]\n\tb = c\n\n\n\tb = \\q\n", 5)
        ]
        for (contents, line) in refused {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            for args in [["--get", "a.b"], ["--list"], ["x.y", "z"], ["--unset", "a.b"]] {
                let result = try await run(args)
                #expect(result.stderr == "fatal: bad config line \(line) in file \(file.path)\n",
                        "\(args) on \(contents.debugDescription)")
                #expect(result.status == 128, "\(args) on \(contents.debugDescription)")
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == contents)
        }

        // Named as typed.
        try "[a]\n\tb = \"oops\n".write(to: work.appendingPathComponent("rel.cfg"), atomically: true, encoding: .utf8)
        let relative = try await git(["config", "--global", "--list"], root: root, home: home, work: work,
                                     environment: ["GIT_CONFIG_GLOBAL": "rel.cfg"])
        #expect(relative.stderr == "fatal: bad config line 2 in file rel.cfg\n" && relative.status == 128)

        // A repository's own file, which every command reads.
        try "[a]\n\tb = fine\n".write(to: file, atomically: true, encoding: .utf8)
        try initRepository(at: work)
        try "[core]\n\trepositoryformatversion = 0\n[x]\n\ty = \"oops\n".write(
            to: work.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        for args in [["a.b"], ["--list"], ["--unset", "x.y"], ["x.y"]] {
            let result = try await git(["config"] + args, root: root, home: home, work: work)
            #expect(result.stderr == "fatal: bad config line 4 in file .git/config\n", "\(args)")
            #expect(result.status == 128, "\(args)")
        }
    }
}
#endif
