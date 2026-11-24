// `git -C <path>` and `git -c <name>[=<value>]` (issue #260), as git's
// `handle_options` takes them: system git, the built `git` executable and
// the registered `git` command, from the same paths and state.
#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git -C / -c match system git on both entry paths")
struct GitCommandInvocationOracleTests {

    @Test("the built git executable is there to compare")
    func standaloneBinaryIsBuilt() {
        #expect(GitInvocationOracle.standaloneBinary != nil,
                "swift build puts the git executable next to the test bundle")
        #expect(GitInvocationOracle.registeredCommand != nil)
    }

    // MARK: Directories

    @Test("absolute, repeated relative, empty and symlinked -C")
    func directories() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let nested = repo.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("n\n".utf8).write(to: nested.appendingPathComponent("n.txt"))
        try await oracle.gitOK(["add", "nested/n.txt"], in: repo)
        try await oracle.gitOK(["commit", "-q", "-m", "nested"], in: repo)
        try FileManager.default.createDirectory(
            at: oracle.root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        // `link/..` is `repo` on disk, as chdir follows the link first; read
        // as text it would be the root, which is no repository.
        try FileManager.default.createSymbolicLink(
            at: oracle.root.appendingPathComponent("link"), withDestinationURL: nested)
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        let root = oracle.root
        for arguments in [
            ["-C", repo.path, "status", "--short"],
            ["-C", "sub", "-C", "../repo", "rev-parse", "--show-toplevel"],
            ["-C", "", "-C", "repo", "-C", "", "log", "--format=%s"],
            ["-C", "repo", "-C", "nested", "rev-parse", "--show-toplevel"],
            ["-C", "link", "-C", "..", "ls-files"],
            ["-C", "link", "rev-parse", "--show-toplevel"],
            ["-C", "repo", "show", "HEAD:file.txt"]
        ] {
            try await oracle.compare(arguments, in: root)
        }
    }

    @Test("a relative GIT_CONFIG_GLOBAL is read from the -C directory")
    func relativeConfigPath() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try "[a]\n\tb = relative\n".write(
            to: repo.appendingPathComponent("relative.cfg"), atomically: false, encoding: .utf8)
        try await oracle.compare(
            ["-C", "repo", "config", "--list", "--show-origin"], in: oracle.root,
            environment: ["GIT_CONFIG_GLOBAL": "relative.cfg"])
    }

    @Test("a directory that can't be entered")
    func directoryErrors() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let locked = oracle.root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var cases = [
            ["-C", "missing", "status"],
            ["-C", "repo/file.txt", "status"],
            ["-C", "repo/file.txt/below", "status"],
            ["-C", "repo", "-C", "missing", "-c", "a.b=1", "status"]
        ]
        // Root enters a directory without search permission (Linux CI's
        // container runs as root), so only another user can't change to it.
        if geteuid() != 0 {
            cases.append(["-C", "locked", "status"])
        }
        for arguments in cases {
            // Snapshot only the repository: `locked` can't be copied.
            try await oracle.compare(arguments, in: oracle.root, fixture: repo)
        }
    }

    @Test("an option without its operand")
    func missingOperands() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let referenceUsage = try await oracle.printsReferenceUsage()
        for arguments in [["-C"], ["-c"], ["-c", "a.b=1", "-C"], ["-C", ".", "-c"]] {
            let expected = try await oracle.system(arguments, in: oracle.root)
            for entry in GitInvocationOracle.Entry.allCases {
                let actual = try await oracle.port(entry, arguments, in: oracle.root)
                #expect(actual.status == expected.status, "\(entry) \(arguments)")
                #expect(actual.stdout == expected.stdout, "\(entry) \(arguments)")
                if referenceUsage {
                    #expect(actual.stderr == expected.stderr, "\(entry) \(arguments)")
                } else {
                    // The usage lines grow with git's global options, and
                    // the complaint's wording moved too (`no directory given
                    // for -C` before 2.54's `… for '-C' option`); its start
                    // did not.
                    let actualLines = actual.stderr.split(separator: "\n")
                    let expectedLines = expected.stderr.split(separator: "\n")
                    let start = { (line: Substring?) in line?.split(separator: " ").prefix(3) ?? [] }
                    #expect(start(actualLines.first) == start(expectedLines.first), "\(entry) \(arguments)")
                    #expect(actualLines.dropFirst().first?.hasPrefix("usage: git ") == true)
                    #expect(expectedLines.dropFirst().first?.hasPrefix("usage: git ") == true)
                }
            }
        }
    }

    @Test("an attached -C or -c is no global option")
    func attachedSpellings() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        for arguments in [["-Crepo", "status"], ["-ca.b=1", "config", "--list"]] {
            let expected = try await oracle.system(arguments, in: oracle.root)
            #expect(expected.status != 0)
            for entry in GitInvocationOracle.Entry.allCases {
                let actual = try await oracle.port(entry, arguments, in: oracle.root)
                #expect(actual.status != 0, "\(entry) \(arguments)")
                #expect(actual.stdout.isEmpty, "\(entry) \(arguments)")
            }
        }
    }

    // MARK: Subcommand preprocessing after the global options

    @Test("subcommand shorthands still apply after -C / -c")
    func preprocessing() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try Data("one\ntwo\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("--color"))
        for arguments in [
            ["-C", "repo", "diff", "-U0"],
            ["-c", "a.b=1", "-C", "repo", "diff", "-U1", "--", "file.txt"],
            ["-C", "repo", "-c", "a.b=1", "log", "-1", "--format=%s"],
            ["-C", "repo", "diff", "--", "--color"],
            ["-C", "repo", "commit", "-q", "-a", "-m", "-S"]
        ] {
            try await oracle.compare(arguments, in: oracle.root, fixture: repo) {
                try await oracle.gitOK(["log", "--format=%s", "--name-status"], in: repo)
            }
        }
    }

    // MARK: Configuration

    @Test("repeated, valueless, empty and first-'=' -c entries, in order")
    func configurationEntries() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        for arguments in [
            ["-c", "a.b=1", "-c", "A.B=2", "-c", "a.b", "-c", "a.c=", "-c", "x.y=1=2",
             "-C", "repo", "config", "--list", "--show-origin"],
            ["-c", "a.b=1", "-c", "a.b=2", "-C", "repo", "config", "--get", "a.b"],
            ["-c", "a.b", "-C", "repo", "config", "a.b"],
            ["-c", "url.https://example.com/?q=1.insteadOf=x", "-C", "repo", "config", "--list"],
            ["-c", "Sec.Sub Ü.Key=it's !ü \"q\" \\", "-c", "x.y", "-C", "repo", "config", "--list", "--show-origin"],
            // Combining marks right after '=', '\'' and '.'.
            ["-c", "a.b=\u{301}x", "-c", "q.r='\u{301}!\u{301}", "-c", "s.e\u{301}.k=1",
             "-C", "repo", "config", "--list", "--show-origin"],
            ["-c", "a.\u{301}b=1", "-C", "repo", "config", "--list"]
        ] {
            try await oracle.compare(arguments, in: oracle.root)
        }
    }

    @Test("valueless reads as true, empty as false")
    func valuelessAndEmptyBooleans() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        for setting in ["commit.gpgsign", "commit.gpgsign=", "commit.gpgsign=true", "commit.gpgsign=no"] {
            try await oracle.compare(
                ["-C", "repo", "-c", "gpg.format=ssh", "-c", setting, "commit", "-q", "-a", "-m", "two"],
                in: oracle.root, fixture: repo) {
                    try await oracle.gitOK(["log", "--format=%s"], in: repo)
                }
        }
    }

    @Test("-c outranks the files, GIT_CONFIG_COUNT and an inherited GIT_CONFIG_PARAMETERS")
    func precedence() async throws {
        let oracle = try GitInvocationOracle(globalConfig: "[a]\n\tb = global\n")
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try await oracle.gitOK(["config", "a.b", "local"], in: repo)
        let inherited = [
            "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "count",
            "GIT_CONFIG_KEY_1": "c.d", "GIT_CONFIG_VALUE_1": "count",
            "GIT_CONFIG_PARAMETERS": "'a.b'='parameter' 'e.f'= 'g.h=legacy' 'i.j' 'k.l'='it'\\''s'"
        ]
        for arguments in [
            ["-C", "repo", "config", "--list", "--show-origin"],
            ["-C", "repo", "-c", "a.b=cli", "-c", "c.d", "config", "--list", "--show-origin"],
            ["-C", "repo", "-c", "a.b=cli", "config", "--get", "a.b"],
            ["-C", "repo", "config", "--get", "a.b"]
        ] {
            try await oracle.compare(arguments, in: oracle.root, environment: inherited)
        }
    }

    @Test("-c include.path reads the file in its place, as git's command-line includes do")
    func commandLineIncludes() async throws {
        let oracle = try GitInvocationOracle(globalConfig: "[user]\n\tname = Global\n")
        defer { oracle.cleanup() }
        try await oracle.repository()
        let root = oracle.root.path
        try "[user]\n\tname = Included\n[include]\n\tpath = nested.cfg\n".write(
            to: oracle.root.appendingPathComponent("identity.cfg"), atomically: false, encoding: .utf8)
        try "[nest]\n\ted = yes\n".write(
            to: oracle.root.appendingPathComponent("nested.cfg"), atomically: false, encoding: .utf8)
        let identity = "include.path=\(root)/identity.cfg"
        for arguments in [
            ["-c", "user.name=Before", "-c", identity, "-c", "x.after=1",
             "-C", "repo", "config", "--list", "--show-origin"],
            ["-c", identity, "-C", "repo", "config", "--get", "user.name"],
            ["-c", identity, "-c", "user.name=After", "-C", "repo", "config", "--get", "user.name"],
            ["-c", "user.name=Before", "-c", identity, "-C", "repo", "config", "--get", "user.name"],
            ["-c", identity, "-C", "repo", "config", "--get", "nest.ed"],
            ["-c", "include.path=~/../identity.cfg", "-C", "repo", "config", "--get", "user.name"],
            ["-c", "include.path=\(root)/missing.cfg", "-C", "repo", "config", "--get", "user.name"],
            ["-c", "include.path=relative.cfg", "-C", "repo", "config", "--list"],
            ["-c", "include.path", "-C", "repo", "config", "--list"],
            ["-c", "include.path=", "-C", "repo", "config", "--list"],
            ["-c", "include.path=relative.cfg", "-c", "bad", "-C", "repo", "config", "--list"],
            ["-c", "bad", "-c", "include.path=relative.cfg", "-C", "repo", "config", "--list"]
        ] {
            try await oracle.compare(arguments, in: oracle.root)
        }
        // A command that reads no config never sees the bad include.
        try await oracle.compare(["-c", "include.path=relative.cfg", "version"], in: oracle.root, stdout: false)
    }

    @Test("what a command writes goes to the repository's config, never to a -c include")
    func commandLineIncludeIsNotWritten() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let work = oracle.root.appendingPathComponent("work.cfg")
        try "[user]\n\tname = Included\n".write(to: work, atomically: false, encoding: .utf8)
        let include = "include.path=\(work.path)"
        let state = { () async throws -> String in
            // Values, not text: libgit2 lays a file out its own way.
            let local = try await oracle.system(
                ["config", "--file", ".git/config", "--get-regexp", "^remote\\."], in: repo).stdout
            let included = try String(contentsOf: work, encoding: .utf8)
            return "local:\n\(local)included:\n\(included)"
        }
        try await oracle.gitOK(["remote", "add", "upstream", "https://example.com/u.git"], in: repo)
        for arguments in [
            ["-c", include, "-C", "repo", "remote", "add", "origin", "https://example.com/o.git"],
            ["-c", include, "-c", "x.after=1", "-C", "repo", "remote", "set-url", "upstream", "https://example.com/v.git"],
            ["-c", include, "-C", "repo", "remote", "rename", "upstream", "renamed"]
        ] {
            try await oracle.compare(arguments, in: oracle.root, state: state)
        }
    }

    @Test("clone checks out with the invocation's config, -c or GIT_CONFIG_COUNT")
    func cloneConfiguration() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let source = try await oracle.repository("source")
        let destination = oracle.root.appendingPathComponent("dest")
        let state = { () async throws -> String in
            let text = try Data(contentsOf: destination.appendingPathComponent("file.txt"))
            // -c is not written into the clone's config.
            let autocrlf = try await oracle.system(
                ["config", "--file", ".git/config", "--get", "core.autocrlf"], in: destination)
            return "file.txt: \(Array(text))\ncore.autocrlf: \(autocrlf.status) \(autocrlf.stdout)"
        }
        try await oracle.compare(
            ["-c", "core.autocrlf=true", "clone", "-q", source.path, "dest"], in: oracle.root, state: state)
        try await oracle.compare(
            ["clone", "-q", source.path, "dest"], in: oracle.root,
            environment: ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.autocrlf", "GIT_CONFIG_VALUE_0": "true"],
            state: state)
    }

    @Test("keys are checked when the config is read, in git's order and words")
    func configurationErrors() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        for arguments in [
            ["-c", "invalid", "-C", "repo", "config", "--list"],
            ["-c", ".b=1", "-C", "repo", "config", "--list"],
            ["-c", "a.=1", "-C", "repo", "config", "--list"],
            ["-c", "a.1b=1", "-C", "repo", "config", "--list"],
            ["-c", "", "-C", "repo", "config", "--list"],
            ["-c", "=v", "-C", "repo", "config", "--list"],
            ["-c", "a.x\ny.z=1", "-C", "repo", "config", "--list"],
            ["-c", "a.b=1", "-c", "invalid", "-c", "c.d=1", "-C", "repo", "status"]
        ] {
            try await oracle.compare(arguments, in: oracle.root)
        }
        // A command that reads no config never sees the bad key.
        try await oracle.compare(["-c", "invalid", "version"], in: oracle.root, stdout: false)
        // GIT_CONFIG_COUNT is read before GIT_CONFIG_PARAMETERS.
        try await oracle.compare(["-c", "invalid", "-C", "repo", "config", "--list"], in: oracle.root,
                                 environment: ["GIT_CONFIG_COUNT": "x"])
    }

    @Test("an inherited GIT_CONFIG_PARAMETERS git can't read")
    func malformedInheritedParameters() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        for parameters in ["'a.b", "a.b=1", "'a.b'x", "'=x'", "''=1", "'a.b'='x'y", "'a.b'='1''c.d'"] {
            try await oracle.compare(["-C", "repo", "-c", "e.f=1", "config", "--list"], in: oracle.root,
                                     environment: ["GIT_CONFIG_PARAMETERS": parameters])
        }
    }

    // MARK: Commit identity

    @Test("-c user.name / user.email set the commit's author and committer")
    func commitIdentity() async throws {
        let oracle = try GitInvocationOracle(globalConfig: "[user]\n\tname = Global\n\temail = global@example.com\n")
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        let identity = { () async throws -> String in
            try await oracle.gitOK(["log", "-1", "--format=%an|%ae|%cn|%ce|%s"], in: repo)
        }
        try await oracle.compare(
            ["-C", "repo", "-c", "user.name=CLI Name", "-c", "user.email=cli@example.com",
             "commit", "-q", "-a", "-m", "cli"],
            in: oracle.root, fixture: repo, state: identity)
        // Over GIT_CONFIG_COUNT's name, with its email left alone.
        try await oracle.compare(
            ["-c", "user.name=CLI Name", "-C", "repo", "commit", "-q", "-a", "-m", "mixed"],
            in: oracle.root,
            environment: ["GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Count",
                          "GIT_CONFIG_KEY_1": "user.email", "GIT_CONFIG_VALUE_1": "count@example.com"],
            fixture: repo, state: identity)
    }

    @Test("a commit reads its identity from a -c include, in its place among the entries")
    func commitIdentityFromInclude() async throws {
        let oracle = try GitInvocationOracle(globalConfig: "[user]\n\tname = Global\n\temail = global@example.com\n")
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let work = oracle.root.appendingPathComponent("work.cfg")
        try "[user]\n\tname = Included\n\temail = included@example.com\n".write(
            to: work, atomically: false, encoding: .utf8)
        let include = "include.path=\(work.path)"
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        let identity = { () async throws -> String in
            try await oracle.gitOK(["log", "-1", "--format=%an|%ae|%cn|%ce|%s"], in: repo)
        }
        for arguments in [
            ["-c", include, "-C", "repo", "commit", "-q", "-a", "-m", "included"],
            ["-c", "user.name=Before", "-c", include, "-c", "user.email=after@example.com",
             "-C", "repo", "commit", "-q", "-a", "-m", "ordered"]
        ] {
            try await oracle.compare(arguments, in: oracle.root, state: identity)
        }
    }
}
#endif
