// `git -c includeIf.<condition>.path=…` and the same entry in
// `GIT_CONFIG_COUNT` (issue #287), as Git 2.54's `include_condition_is_true`
// decides it: system git, the built `git` executable and the registered
// `git` command, from the same paths and state.
#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git -c includeIf matches system git on both entry paths")
struct GitCommandIncludeIfOracleTests {

    /// `settings` as `-c` options and, separately, as `GIT_CONFIG_COUNT`
    /// entries, each followed by `rest`: both must match system git.
    private func compareBoth(
        _ oracle: GitInvocationOracle, _ settings: [(String, String)], _ rest: [String],
        in directory: URL? = nil, fixture: URL? = nil, state: (() async throws -> String)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let directory = directory ?? oracle.root
        let options = settings.flatMap { ["-c", "\($0.0)=\($0.1)"] }
        try await oracle.compare(options + rest, in: directory, fixture: fixture, state: state,
                                 sourceLocation: sourceLocation)
        var counted = ["GIT_CONFIG_COUNT": "\(settings.count)"]
        for (index, setting) in settings.enumerated() {
            counted["GIT_CONFIG_KEY_\(index)"] = setting.0
            counted["GIT_CONFIG_VALUE_\(index)"] = setting.1
        }
        try await oracle.compare(rest, in: directory, environment: counted, fixture: fixture, state: state,
                                 sourceLocation: sourceLocation)
    }

    private func write(_ text: String, _ name: String, in oracle: GitInvocationOracle) throws -> String {
        let file = oracle.root.appendingPathComponent(name)
        try text.write(to: file, atomically: false, encoding: .utf8)
        return file.path
    }

    private let getName = ["-C", "repo", "config", "--get", "user.name"]

    // MARK: Regression

    @Test("-c includeIf.onbranch:main.path reads the file on main")
    func onbranchMain() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        let expected = try await oracle.compare(
            ["-c", "includeIf.onbranch:main.path=\(identity)"] + getName, in: oracle.root)
        #expect(expected == .init(stdout: "Included\n", stderr: "", status: 0))
    }

    // MARK: gitdir

    @Test("gitdir: and gitdir/i: against the repository's git directory")
    func gitdir() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        try FileManager.default.createSymbolicLink(
            at: oracle.root.appendingPathComponent("link"), withDestinationURL: repo)
        let root = oracle.root.path
        for condition in [
            "gitdir:\(root)/repo/", "gitdir:\(root)/repo/.git", "gitdir:\(root)/repo",
            "gitdir:\(root)/other/", "gitdir:**/repo/", "gitdir:repo/", "gitdir:\(root)/link/",
            "gitdir:\(root.uppercased())/REPO/", "gitdir/i:\(root.uppercased())/REPO/", "gitdir/i:**/REPO/"
        ] {
            try await compareBoth(oracle, [("includeIf.\(condition).path", identity)], getName)
        }
        // Through a symlinked -C: the real git directory is matched.
        try await compareBoth(oracle, [("includeIf.gitdir:\(root)/repo/.path", identity)],
                              ["-C", "link", "config", "--get", "user.name"])
        try await compareBoth(oracle, [("includeIf.gitdir:\(root)/link/.path", identity)],
                              ["-C", "link", "config", "--get", "user.name"])
        // `~/` in the target is the shell's HOME.
        try "[user]\n\tname = Home\n".write(
            to: oracle.home.appendingPathComponent("home.cfg"), atomically: false, encoding: .utf8)
        try await compareBoth(oracle, [("includeIf.gitdir:**/repo/.path", "~/home.cfg")], getName)
    }

    // MARK: onbranch

    @Test("onbranch: on a branch, a pattern, a nested branch, unborn and detached")
    func onbranch() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        for condition in ["onbranch:main", "onbranch:ma*", "onbranch:other", "onbranch:feature/**"] {
            try await compareBoth(oracle, [("includeIf.\(condition).path", identity)], getName)
        }
        try await oracle.gitOK(["checkout", "-q", "-b", "feature/deep/x"], in: repo)
        for condition in ["onbranch:feature/**", "onbranch:feature/", "onbranch:feature/*", "onbranch:main"] {
            try await compareBoth(oracle, [("includeIf.\(condition).path", identity)], getName)
        }
        try await oracle.gitOK(["checkout", "-q", "--detach"], in: repo)
        try await compareBoth(oracle, [("includeIf.onbranch:feature/**.path", identity)], getName)
        let unborn = oracle.root.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        try await oracle.gitOK(["init", "-q", "-b", "fresh"], in: unborn)
        try await compareBoth(oracle, [("includeIf.onbranch:fresh.path", identity)],
                              ["-C", "unborn", "config", "--get", "user.name"])
    }

    // MARK: hasconfig

    @Test("hasconfig:remote.*.url: sees every URL git would, in and out of a repository")
    func hasconfig() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        let remote = try write("[remote \"x\"]\n\turl = https://example.com/x.git\n", "remote.cfg", in: oracle)
        let condition = "includeIf.hasconfig:remote.*.url:https://example.com/**.path"
        // Nothing has such a URL yet.
        try await compareBoth(oracle, [(condition, identity)], getName)
        // A later entry, in and out of a repository.
        try await compareBoth(oracle, [(condition, identity), ("remote.y.url", "https://example.com/y")], getName)
        try await compareBoth(oracle, [(condition, identity), ("remote.y.url", "https://example.com/y")],
                              ["config", "--get", "user.name"])
        // A later unconditional include.
        try await compareBoth(oracle, [(condition, identity), ("include.path", remote)], getName)
        // The repository's own config.
        try await oracle.gitOK(["remote", "add", "origin", "https://example.com/o.git"], in: repo)
        try await compareBoth(oracle, [(condition, identity)], getName)
    }

    @Test("hasconfig targets are read even when nothing matches, and may not set a URL")
    func hasconfigTargets() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        let remote = try write("[remote \"x\"]\n\turl = https://example.com/x.git\n", "remote.cfg", in: oracle)
        let nowhere = "includeIf.hasconfig:remote.*.url:https://nowhere.example/**.path"
        let root = oracle.root.path
        try await compareBoth(oracle, [(nowhere, remote)], getName)
        try await compareBoth(oracle, [("includeIf.gitdir:\(root)/repo/.path", remote), (nowhere, identity)], getName)
        try await compareBoth(oracle, [(nowhere, "\(root)/missing.cfg")], getName)
        // Root reads any file.
        if geteuid() != 0 {
            let locked = try write("[user]\n\tname = Locked\n", "locked.cfg", in: oracle)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
            // Snapshot only the repository: `locked.cfg` can't be copied.
            try await compareBoth(oracle, [(nowhere, locked)], getName, fixture: repo)
            try await compareBoth(oracle, [("includeIf.onbranch:main.path", locked)], getName, fixture: repo)
            // A condition that doesn't hold never opens its file.
            try await compareBoth(oracle, [("includeIf.onbranch:other.path", locked)], getName, fixture: repo)
        }
    }

    @Test("a target there but not readable as a file: a symlink loop or a directory")
    func unreachableTargets() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let root = oracle.root.path
        let directory = oracle.root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/loop1", withDestinationPath: "loop2")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/loop2", withDestinationPath: "loop1")
        let nowhere = "includeIf.hasconfig:remote.*.url:https://nowhere.example/**.path"
        // Snapshot only the repository: the loop can't be copied.
        for key in ["includeIf.onbranch:main.path", nowhere, "include.path"] {
            try await compareBoth(oracle, [(key, "\(root)/loop1")], getName, fixture: repo)
        }
        try await compareBoth(oracle, [("include.path", directory.path)], getName, fixture: repo)
        // GitKit reports no path for a conditional directory target
        // (Cocoanetics/GitKit#123).
        for key in ["includeIf.onbranch:main.path", nowhere] {
            await withKnownIssue("Cocoanetics/GitKit#123") {
                try await oracle.compare(["-c", "\(key)=\(directory.path)"] + getName, in: oracle.root, fixture: repo)
            }
        }
    }

    // MARK: Relative patterns and targets

    @Test("a relative condition or target from the command line")
    func relative() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        // Git's nonfatal diagnostic, and the include.
        try await compareBoth(oracle, [("includeIf.gitdir:./x/.path", identity)], getName)
        // No repository: the condition doesn't hold, and nothing is said.
        try await compareBoth(oracle, [("includeIf.gitdir:./x/.path", identity)], ["config", "--get", "user.name"])
        // A relative target is an error only once it is reached.
        try await compareBoth(oracle, [("includeIf.onbranch:main.path", "relative.cfg")], getName)
        try await compareBoth(oracle, [("includeIf.onbranch:other.path", "relative.cfg")], getName)
        try await compareBoth(oracle, [("includeIf.onbranch:main.path", "")], getName)
        try await oracle.compare(["-c", "includeIf.onbranch:other.path"] + getName, in: oracle.root)
        try await oracle.compare(["-c", "includeIf.onbranch:other.path=~nosuchuser/x"] + getName, in: oracle.root)
    }

    @Test("what GitKit can't take yet: a valueless or unexpandable target whose condition holds")
    func unexpressedTargets() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        // Git checks the value only once the condition holds; GitKit's
        // `includeIf(condition:path:)` takes an expanded path
        // (Cocoanetics/GitKit#118).
        for setting in ["includeIf.onbranch:main.path", "includeIf.onbranch:main.path=~nosuchuser/x"] {
            await withKnownIssue("Cocoanetics/GitKit#118") {
                try await oracle.compare(["-c", setting] + getName, in: oracle.root)
            }
        }
    }

    // MARK: Order and origin

    @Test("an includeIf's file takes its place among the entries, with its origin")
    func precedenceAndOrigin() async throws {
        let oracle = try GitInvocationOracle(globalConfig: "[user]\n\tname = Global\n")
        defer { oracle.cleanup() }
        try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        let other = try write("[user]\n\tname = Other\n\temail = other@example.com\n", "other.cfg", in: oracle)
        let matched = ("includeIf.onbranch:main.path", identity)
        let unmatched = ("includeIf.onbranch:other.path", other)
        let list = ["-C", "repo", "config", "--list", "--show-origin"]
        try await compareBoth(oracle, [("user.name", "Before"), matched, ("x.after", "1"), unmatched], list)
        try await compareBoth(oracle, [("user.name", "Before"), matched], getName)
        try await compareBoth(oracle, [matched, ("user.name", "After")], getName)
        try await compareBoth(oracle, [("include.path", other), matched, unmatched], list)
        try await compareBoth(oracle, [matched, ("include.path", other)], getName)
    }

    @Test("files an includeIf reads include in turn, file-relative conditions and all")
    func nestedIncludes() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        _ = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        _ = try write("[nest]\n\ted = yes\n", "nested.cfg", in: oracle)
        let outer = try write(
            "[includeIf \"gitdir:./\"]\n\tpath = identity.cfg\n[include]\n\tpath = nested.cfg\n[a]\n\tb = outer\n",
            "outer.cfg", in: oracle)
        try await compareBoth(oracle, [("includeIf.onbranch:main.path", outer)],
                              ["-C", "repo", "config", "--list", "--show-origin"])
        // Ten levels of includes are read.
        for level in 1...10 {
            _ = try write("[include]\n\tpath = level\(level + 1).cfg\n", "level\(level).cfg", in: oracle)
        }
        _ = try write("[user]\n\tname = Deep\n", "level11.cfg", in: oracle)
        let second = oracle.root.appendingPathComponent("level2.cfg").path
        try await compareBoth(oracle, [("includeIf.onbranch:main.path", second)], getName)
    }

    @Test("the include depth error names the files")
    func includeDepth() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        for level in 1...11 {
            _ = try write("[include]\n\tpath = level\(level + 1).cfg\n", "level\(level).cfg", in: oracle)
        }
        _ = try write("[user]\n\tname = Deep\n", "level12.cfg", in: oracle)
        let first = oracle.root.appendingPathComponent("level1.cfg").path
        // GitKit's depth error carries no paths (Cocoanetics/GitKit#119).
        await withKnownIssue("Cocoanetics/GitKit#119") {
            try await oracle.compare(["-c", "includeIf.onbranch:main.path=\(first)"] + getName, in: oracle.root)
        }
    }

    // MARK: Diagnostics

    @Test("a relative gitdir condition is reported as often as git reads the config")
    func diagnosticCount() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let identity = try write("[user]\n\tname = Included\n", "identity.cfg", in: oracle)
        let relative = "includeIf.gitdir:./x/.path=\(identity)"
        // Git reads the config once for these, so says it once.
        for command in [["config", "--get", "user.name"], ["rev-parse", "--git-dir"], ["config", "user.email", "x@y"]] {
            try await oracle.compare(["-c", relative, "-C", "repo"] + command, in: oracle.root)
        }
        // Others read it more than once, and git says it each time; the
        // port says it once per invocation.
        for command in [["config", "--list"], ["status", "--short"]] {
            await withKnownIssue("git repeats the diagnostic for each config read") {
                try await oracle.compare(["-c", relative, "-C", "repo"] + command, in: oracle.root)
            }
        }
    }

    // MARK: Writes

    @Test("a command writes the repository's config, never a file an includeIf reads")
    func includeIfIsNotWritten() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        let work = oracle.root.appendingPathComponent("work.cfg")
        try "[user]\n\tname = Included\n".write(to: work, atomically: false, encoding: .utf8)
        let state = { () async throws -> String in
            let local = try await oracle.system(
                ["config", "--file", ".git/config", "--get-regexp", "^remote\\."], in: repo).stdout
            let included = try String(contentsOf: work, encoding: .utf8)
            return "local:\n\(local)included:\n\(included)"
        }
        try await oracle.gitOK(["remote", "add", "upstream", "https://example.com/u.git"], in: repo)
        let root = oracle.root.path
        for include in ["includeIf.onbranch:main.path", "includeIf.gitdir:\(root)/repo/.path"] {
            for command in [
                ["remote", "add", "origin", "https://example.com/o.git"],
                ["remote", "set-url", "upstream", "https://example.com/v.git"],
                ["remote", "rename", "upstream", "renamed"]
            ] {
                try await compareBoth(oracle, [(include, work.path)], ["-C", "repo"] + command, state: state)
            }
        }
    }
}
#endif
