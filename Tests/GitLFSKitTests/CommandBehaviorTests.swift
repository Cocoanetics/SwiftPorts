import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

@Suite("Git LFS command operations without an oracle")
struct CommandBehaviorTests {
    let host = IsolatedLFSHost()

    private func withRepository<T: Sendable>(
        _ name: String,
        environment extra: [String: String] = [:],
        body: () async throws -> T
    ) async throws -> T {
        let repo = host.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let variables = host.variables.merging(extra) { _, new in new }
        let shell = Shell(environment: Environment(variables: variables, workingDirectory: repo.path))
        shell.sandbox = host.sandbox
        return try await shell.withCurrent {
            try await GitClient(workingDirectory: repo).initRepository(initialBranch: "main")
            return try await body()
        }
    }

    @Test func pointerChecks() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let path = host.root.appendingPathComponent("pointer")
            let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 10).encoded
            try pointer.write(to: path, atomically: false, encoding: .utf8)
            var options = LFSPointerOptions()
            options.file = path.path
            options.check = true
            options.strict = true
            #expect(try await options.run().status == 0)
            try ("\n" + pointer).write(to: path, atomically: false, encoding: .utf8)
            #expect(try await options.run().status == 2)
            options.strict = false
            #expect(try await options.run().status == 0)
            try "not a pointer".write(to: path, atomically: false, encoding: .utf8)
            let result = try await options.run()
            #expect(result.status == 1 && result.stdout.isEmpty && result.stderr.isEmpty)
        }
    }

    @Test func fileInstallationOutsideRepo() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            var options = FilterOptions()
            options.file = host.root.appendingPathComponent("config").path
            options.skipSmudge = true
            let client = GitClient(workingDirectory: host.root)
            let installed = try await options.install(client)
            #expect(installed.status == 0 && installed.stdout == "Git LFS initialized.\n")
            let file = FilterConfiguration(path: URL(fileURLWithPath: options.file))
            #expect(try await file.value("filter.lfs.clean") == "git-lfs clean -- %f")
            #expect(try await file.value("filter.lfs.smudge") == "git-lfs smudge --skip -- %f")
            #expect(try await file.value("filter.lfs.process") == "git-lfs filter-process --skip")
            #expect(try await file.value("filter.lfs.required") == "true")
            #expect(try await options.uninstall(client).status == 0)
            #expect(try String(contentsOfFile: options.file, encoding: .utf8).isEmpty)
        }
    }

    @Test func hooksRefuseForeignScripts() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let hook = Hook(type: "pre-push", directory: host.root.appendingPathComponent("hooks"))
            try await hook.install()
            let bytes = try Data(contentsOf: hook.path)
            #expect(bytes == Data((hook.contents + "\n").utf8))
            try "#!/bin/sh\necho foreign\n".write(to: hook.path, atomically: false, encoding: .utf8)
            await #expect(throws: LFSFailure.self) { try await hook.install() }
            #expect(try String(contentsOf: hook.path, encoding: .utf8) == "#!/bin/sh\necho foreign\n")
            try await hook.install(force: true)
            #expect(try Data(contentsOf: hook.path) == bytes)
            try await hook.uninstall()
            #expect(!FileManager.default.fileExists(atPath: hook.path.path))
        }
    }

    @Test("pointer stdin stops at the upstream 1024-byte cutoff", .timeLimit(.minutes(1)))
    func pointerInputCutoff() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        defer { continuation.finish() }
        let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 10).encoded
        continuation.yield(Data(pointer.utf8) + Data(repeating: 0x20, count: Pointer.blobSizeCutoff))
        let shell = Shell(stdin: InputSource(bytes: stream))
        let result = try await shell.withCurrent {
            var options = LFSPointerOptions()
            options.stdin = true
            options.check = true
            return try await options.run()
        }
        #expect(result.status == 0)
    }

    @Test func trackWritesLocalRuleWhenExternalRuleMatches() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("ExternalAttributes") {
            let external = host.root.appendingPathComponent("external-attributes")
            try "*.bin filter=lfs diff=lfs merge=lfs -text\n"
                .write(to: external, atomically: false, encoding: .utf8)
            let client = GitClient()
            try await client.configSet("core.attributesfile", external.path)
            // Pin the output ending so this regression is identical on every OS.
            try await client.configSet("core.autocrlf", "true")

            let listing = try await TrackOptions().track([], client: client)
            #expect(listing.stdout.contains("*.bin"))
            #expect(listing.stdout.contains("external-attributes"))

            let result = try await TrackOptions().track(["*.bin"], client: client)
            #expect(result.stdout == "Tracking \"*.bin\"\n")
            #expect(try String(contentsOf: Shell.currentDirectory.appendingPathComponent(".gitattributes"),
                               encoding: .utf8) == "*.bin filter=lfs diff=lfs merge=lfs -text\r\n")
        }
    }

    @Test func crlfAttributeRulesAreReadAndPreserved() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("CRLFAttributes") {
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            let initial = "# comment\r\n*.bin filter=lfs diff=lfs merge=lfs -text\r\n"
            try initial.write(to: path, atomically: false, encoding: .utf8)
            let client = GitClient()

            let listing = try await TrackOptions().track([], client: client)
            #expect(listing.stdout == "Listing tracked patterns\n    *.bin (.gitattributes)\n"
                + "Listing excluded patterns\n")
            let tracked = try await TrackOptions().track(["*.dat"], client: client)
            #expect(tracked.stdout == "Tracking \"*.dat\"\n")
            #expect(try String(contentsOf: path, encoding: .utf8)
                == initial + "*.dat filter=lfs diff=lfs merge=lfs -text\r\n")

            let untracked = try await TrackOptions().untrack(["*.bin"], client: client)
            #expect(untracked.stdout == "Untracking \"*.bin\"\n")
            #expect(try String(contentsOf: path, encoding: .utf8)
                == "# comment\n*.dat filter=lfs diff=lfs merge=lfs -text\n")
        }
    }

    @Test func trackHookSuppressionAcceptsEveryTruthySpelling() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        for value in ["TRUE", "yes", "ON", "t", "1"] {
            try await withRepository("NoHooks-\(value)", environment: ["GIT_LFS_TRACK_NO_INSTALL_HOOKS": value]) {
                let client = GitClient()
                let result = try await TrackOptions().track([], client: client)
                #expect(result.status == 0)
                #expect(!FileManager.default.fileExists(
                    atPath: Shell.currentDirectory.appendingPathComponent(".git/hooks/pre-push").path))
            }
        }
    }

    @Test func configIncludesAreAuthorized() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let root = host.root.appendingPathComponent("IncludeRoot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFSInclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("private.gitconfig")
        try "[filter \"lfs\"]\n\tclean = stolen\n".write(to: secret, atomically: false, encoding: .utf8)
        let settings = root.appendingPathComponent("settings.cfg")
        // Git config treats a backslash as an escape, so `C:\\Users` is not
        // a path. Forward slashes are the include spelling libgit2 follows.
        let outsidePath = secret.path.replacingOccurrences(of: "\\", with: "/")
        try "[include]\n\tpath = \(outsidePath)\n".write(to: settings, atomically: false, encoding: .utf8)
        let shell = Shell(environment: Environment(
            variables: ["GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: root.path))
        shell.sandbox = .rooted(at: root)
        try await shell.withCurrent {
            var options = FilterOptions()
            options.file = settings.path
            options.skipRepo = true
            let client = GitClient(workingDirectory: root)
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await options.install(client)
            }
            let inside = root.appendingPathComponent("extra.cfg")
            try "[filter \"lfs\"]\n\tclean = from-include\n".write(
                to: inside, atomically: false, encoding: .utf8)
            try "[include]\n\tpath = extra.cfg\n".write(to: settings, atomically: false, encoding: .utf8)
            let config = try await FilterConfiguration.open(options, client: client)
            #expect(try await config.value("filter.lfs.clean") == "from-include")
        }
    }

    @Test func uninstallKeepsCaseSensitiveSubsections() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let path = host.root.appendingPathComponent("both.cfg")
            let original = """
            [filter "lfs"]
            \tclean = git-lfs clean -- %f
            [filter "LFS"]
            \tclean = keep-me
            [filter.LFS]
            \tprocess = keep-dot
            [FILTER "lfs"]
            \tsmudge = remove-me
            [other]
            \tx = 1

            """
            try original.write(to: path, atomically: false, encoding: .utf8)
            var options = FilterOptions()
            options.file = path.path
            options.skipRepo = true
            #expect(try await options.uninstall(GitClient(workingDirectory: host.root)).status == 0)
            let text = try String(contentsOf: path, encoding: .utf8)
            #expect(!text.contains("git-lfs clean"))
            #expect(!text.contains("remove-me"))
            #expect(text.contains("keep-me"))
            #expect(text.contains("keep-dot"))
            #expect(text.contains("[other]"))
        }
    }

    @Test func trackDoesNotRequireHostAttributeFiles() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let repo = host.root.appendingPathComponent("RootedTrack")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        // HOME is absent: the global attributes fallback must use the sandbox home.
        let shell = Shell(environment: Environment(
            variables: ["GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: repo.path))
        shell.sandbox = .rooted(at: host.root)
        try await shell.withCurrent {
            try await GitClient(workingDirectory: repo).initRepository(initialBranch: "main")
            let result = try await TrackOptions().track(["*.bin"], client: GitClient())
            #expect(result.status == 0)
            #expect(result.stdout.contains("Tracking \"*.bin\""))
            let text = try String(contentsOf: repo.appendingPathComponent(".gitattributes"), encoding: .utf8)
            #expect(text.contains("*.bin filter=lfs"))
        }
    }

    @Test func trackTouchesBasenameMatches() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("BasenameTouch") {
            let assets = Shell.currentDirectory.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let file = assets.appendingPathComponent("model.bin")
            try Data("payload".utf8).write(to: file)
            let client = GitClient()
            try await client.add(paths: ["assets/model.bin"])
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
            var options = TrackOptions()
            options.verbose = true
            let result = try await options.track(["model.bin"], client: client)
            #expect(result.stdout.contains(
                "Found 1 files previously added to Git matching pattern: model.bin"))
            #expect(result.stdout.contains("Touching \"assets/model.bin\""))
            let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            #expect((modified ?? .distantPast) > Date(timeIntervalSince1970: 1))
        }
    }

    @Test func pointerAndConfigResolveVirtualPaths() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workspace = host.root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let pointer = Pointer(oid: String(repeating: "b", count: 64), size: 4).encoded
        try pointer.write(to: workspace.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
        let mapping = PathMapping(mounts: [.init(virtual: "/workspace", host: workspace.path)])
        let shell = Shell(environment: Environment(workingDirectory: "/workspace"))
        shell.sandbox = .confined(to: mapping, home: "/workspace")
        try await shell.withCurrent {
            var options = LFSPointerOptions()
            options.file = "/workspace/payload"
            options.check = true
            let checked = try await options.run()
            #expect(checked.status == 0)
            var filter = FilterOptions()
            filter.file = "/workspace/settings.cfg"
            filter.skipRepo = true
            let installed = try await filter.install(GitClient())
            #expect(installed.status == 0)
            #expect(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("settings.cfg").path))
        }
    }

    @Test func unspecifiedMacrosStayExcluded() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("UnspecifiedMacro") {
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            let original = "[attr]large filter=lfs diff=lfs merge=lfs -text\n"
                + "*.dat large\n*.bin !large\n"
            try original.write(to: path, atomically: false, encoding: .utf8)
            let client = GitClient()
            let listing = try await TrackOptions().track([], client: client)
            #expect(listing.stdout == "Listing tracked patterns\n    *.dat (.gitattributes)\n"
                + "Listing excluded patterns\n    *.bin (.gitattributes)\n")
            let again = try await TrackOptions().track(["*.bin"], client: client)
            #expect(again.stdout == "\"*.bin\" already supported\n")
            #expect(try String(contentsOf: path, encoding: .utf8) == original)
            let supported = try await TrackOptions().track(["*.dat"], client: client)
            #expect(supported.stdout == "\"*.dat\" already supported\n")
        }
    }

    @Test func quotedAttributePatternsUseGoEscapes() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("QuotedPattern") {
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            let original = "\"caf\\303\\251.bin\" filter=lfs diff=lfs merge=lfs -text\n"
            try original.write(to: path, atomically: false, encoding: .utf8)
            let client = GitClient()
            var listingOptions = TrackOptions()
            listingOptions.json = true
            let listing = try await listingOptions.track([], client: client)
            #expect(listing.stdout.contains("caf\u{00e9}.bin"))
            let again = try await TrackOptions().track(["caf\u{00e9}.bin"], client: client)
            #expect(again.stdout.contains("already supported"))
            #expect(try String(contentsOf: path, encoding: .utf8) == original)
        }
    }

    @Test func attributeLineEndingsFollowTheMajority() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("MajorityEndings") {
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            let initial = "# comment\r\n*.bin filter=lfs diff=lfs merge=lfs -text\n"
                + "*.png filter=lfs diff=lfs merge=lfs -text\n"
            try initial.write(to: path, atomically: false, encoding: .utf8)
            let client = GitClient()
            try await client.configSet("core.autocrlf", "true")
            let tracked = try await TrackOptions().track(["*.dat"], client: client)
            #expect(tracked.stdout == "Tracking \"*.dat\"\n")
            #expect(try String(contentsOf: path, encoding: .utf8)
                == "# comment\n*.bin filter=lfs diff=lfs merge=lfs -text\n"
                + "*.png filter=lfs diff=lfs merge=lfs -text\n"
                + "*.dat filter=lfs diff=lfs merge=lfs -text\n")
        }
        try await withRepository("MissingNewline") {
            let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
            try "*.bin filter=lfs diff=lfs merge=lfs -text".write(to: path, atomically: false, encoding: .utf8)
            let client = GitClient()
            try await client.configSet("core.autocrlf", "true")
            _ = try await TrackOptions().track(["*.dat"], client: client)
            #expect(try String(contentsOf: path, encoding: .utf8)
                == "*.bin filter=lfs diff=lfs merge=lfs -text\r\n"
                + "*.dat filter=lfs diff=lfs merge=lfs -text\r\n")
        }
    }

    @Test func repositoryPrefixIgnoresDirectorySpelling() {
        #expect(TrackOptions.repositoryPrefix(cwd: "/repo", root: "/repo/") == "")
        #expect(TrackOptions.repositoryPrefix(cwd: "/repo/sub", root: "/repo") == "sub/")
        #expect(TrackOptions.repositoryPrefix(cwd: "/other", root: "/repo") == "")
        #expect(TrackOptions.repositoryPrefix(cwd: #"C:\repo"#, root: "C:/repo/") == "")
        #expect(TrackOptions.repositoryPrefix(cwd: "/C:/repo/assets", root: #"C:\repo"#) == "assets/")
        #expect(TrackOptions.pathBasename("assets/model.bin") == "model.bin")
        #expect(TrackOptions.pathBasename(#"assets\model.bin"#) == "model.bin")
    }

}
