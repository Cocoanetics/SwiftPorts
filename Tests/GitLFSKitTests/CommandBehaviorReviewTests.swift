import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

@Suite("Git LFS review regressions")
struct CommandBehaviorReviewTests {
    let host = IsolatedLFSHost()

    private func withRepository<T: Sendable>(
        _ name: String,
        body: () async throws -> T
    ) async throws -> T {
        let repo = host.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: repo.path))
        shell.sandbox = host.sandbox
        return try await shell.withCurrent {
            try await GitClient(workingDirectory: repo).initRepository(initialBranch: "main")
            return try await body()
        }
    }

    @Test func exclusionPatternsKeepStarsInOneDirectory() {
        #expect(TrackOptions.exclusionMatches("assets/*.bin", path: "assets/model.bin"))
        #expect(!TrackOptions.exclusionMatches("assets/*.bin", path: "assets/sub/model.bin"))
        #expect(!TrackOptions.exclusionMatches("assets/*.bin", path: "assets/sub/.gitkeep.bin"))
        #expect(TrackOptions.exclusionMatches("*.bin", path: "assets/sub/model.bin"))
        #expect(TrackOptions.exclusionMatches("model.bin", path: "assets/model.bin"))
        #expect(TrackOptions.exclusionMatches("/*.bin", path: "model.bin"))
        #expect(!TrackOptions.exclusionMatches("/*.bin", path: "assets/model.bin"))
        #expect(TrackOptions.exclusionMatches("assets/**/*.bin", path: "assets/sub/model.bin"))
        #expect(TrackOptions.exclusionMatches("assets/**/model.bin", path: "assets/model.bin"))
        #expect(TrackOptions.exclusionMatches("**/*.bin", path: "model.bin"))
        #expect(!TrackOptions.exclusionMatches("other/*.bin", path: "assets/model.bin"))
        #expect(TrackOptions.exclusionMatches("assets/file[12].bin", path: "assets/file1.bin"))
        #expect(!TrackOptions.exclusionMatches("assets/?.bin", path: "assets/sub/a.bin"))
    }

    @Test func directoryOnlyDoubleStarRequiresAChildDirectory() {
        #expect(!TrackOptions.exclusionMatches("foo/**/", path: "foo/a"))
        #expect(TrackOptions.exclusionMatches("foo/**/", path: "foo/bar/b"))
        #expect(TrackOptions.exclusionMatches("foo/**/", path: "foo/baz/qux/d"))
        #expect(!TrackOptions.exclusionMatches("foo/**/", path: "other/e"))
        #expect(TrackOptions.exclusionMatches("foo/**", path: "foo/a"))
        #expect(TrackOptions.exclusionMatches("foo/**/**/", path: "foo/bar/b"))
        #expect(!TrackOptions.exclusionMatches("foo/**/**/", path: "foo/a"))
        #expect(!TrackOptions.exclusionMatches("*/**/", path: "foo/a"))
        #expect(TrackOptions.exclusionMatches("*/**/", path: "foo/bar/b"))
        #expect(TrackOptions.exclusionMatches("**/**/", path: "foo/a"))
        #expect(!TrackOptions.exclusionMatches("a/b/**/", path: "a/b/i"))
        #expect(TrackOptions.exclusionMatches("a/b/**/", path: "a/b/c/h"))
        #expect(TrackOptions.exclusionMatches("foo/", path: "foo/a"))
        #expect(TrackOptions.exclusionMatches("**/", path: "foo/a"))
        #expect(!TrackOptions.exclusionMatches("**/", path: "root.txt"))
        #expect(TrackOptions.exclusionMatches("assets/**", path: "assets/model.bin"))
        #expect(TrackOptions.exclusionMatches("foo/**/bar/", path: "foo/bar/b"))
        #expect(!TrackOptions.exclusionMatches("foo/**/bar/**/", path: "foo/bar/b"))
    }

    @Test func trackSlashGlobDoesNotTouchNestedFiles() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await withRepository("SlashGlob") {
            let assets = Shell.currentDirectory.appendingPathComponent("assets", isDirectory: true)
            let nested = assets.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let top = assets.appendingPathComponent("model.bin")
            let deep = nested.appendingPathComponent("model.bin")
            let forbidden = nested.appendingPathComponent(".gitkeep.bin")
            try Data("top".utf8).write(to: top)
            try Data("deep".utf8).write(to: deep)
            try Data("nope".utf8).write(to: forbidden)
            let client = GitClient()
            try await client.add(paths: [
                "assets/model.bin", "assets/sub/model.bin", "assets/sub/.gitkeep.bin"
            ])
            for file in [top, deep, forbidden] {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
            }
            var options = TrackOptions()
            options.verbose = true
            let result = try await options.track(["assets/*.bin"], client: client)
            #expect(result.status == 0)
            #expect(result.stdout.contains(
                "Found 1 files previously added to Git matching pattern: assets/*.bin"))
            #expect(result.stdout.contains("Touching \"assets/model.bin\""))
            #expect(!result.stdout.contains("assets/sub"))
            #expect(!result.stdout.contains("forbidden"))
            let touched = try FileManager.default.attributesOfItem(atPath: top.path)[.modificationDate] as? Date
            #expect((touched ?? .distantPast) > Date(timeIntervalSince1970: 1))
            let nestedDate = try FileManager.default.attributesOfItem(atPath: deep.path)[.modificationDate] as? Date
            #expect((nestedDate ?? .distantFuture) < Date(timeIntervalSince1970: 1))
        }
    }

    @Test func configIncludeUsesTheCallingShellHome() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let homeA = host.root.appendingPathComponent("homeA", isDirectory: true)
        let sideB = host.root.appendingPathComponent("sideB", isDirectory: true)
        let homeB = sideB.appendingPathComponent("homeB", isDirectory: true)
        let workB = sideB.appendingPathComponent("workB", isDirectory: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workB, withIntermediateDirectories: true)
        try "[filter \"lfs\"]\n\tclean = from-a\n".write(
            to: homeA.appendingPathComponent("filters.cfg"), atomically: false, encoding: .utf8)
        try "[filter \"lfs\"]\n\tclean = from-b\n".write(
            to: homeB.appendingPathComponent("filters.cfg"), atomically: false, encoding: .utf8)
        let settings = workB.appendingPathComponent("settings.cfg")
        try "[include]\n\tpath = ~/filters.cfg\n".write(to: settings, atomically: false, encoding: .utf8)

        let shellA = Shell(environment: Environment(
            variables: ["HOME": homeA.path, "GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: homeA.path))
        shellA.sandbox = .rooted(at: homeA)
        _ = try await shellA.withCurrent {
            try await GitClient(workingDirectory: homeA).initRepository(initialBranch: "main")
        }

        let shellB = Shell(environment: Environment(
            variables: ["HOME": homeB.path, "GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: workB.path))
        shellB.sandbox = .rooted(at: sideB)
        try await shellB.withCurrent {
            var options = FilterOptions()
            options.file = settings.path
            options.skipRepo = true
            let config = try await FilterConfiguration.open(options, client: GitClient(workingDirectory: workB))
            #expect(try await config.value("filter.lfs.clean") == "from-b")
        }
    }

    @Test func uninstallRewritesSymlinkTarget() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let real = host.root.appendingPathComponent("real.cfg")
            try "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n[other]\n\tx = 1\n".write(
                to: real, atomically: false, encoding: .utf8)
            let link = host.root.appendingPathComponent("link.cfg")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.cfg")
            var options = FilterOptions()
            options.file = link.path
            options.skipRepo = true
            #expect(try await options.uninstall(GitClient(workingDirectory: host.root)).status == 0)
            let text = try String(contentsOf: real, encoding: .utf8)
            #expect(!text.contains("git-lfs clean"))
            #expect(text.contains("[other]"))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real.cfg")
            #expect(!FileManager.default.fileExists(atPath: real.path + ".lock"))
            #expect(!FileManager.default.fileExists(atPath: link.path + ".lock"))
        }
    }

    @Test func uninstallDeniesSymlinkOutsideTheSandbox() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let box = host.root.appendingPathComponent("box", isDirectory: true)
        let outside = host.root.appendingPathComponent("outside.cfg")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let original = "[filter \"lfs\"]\n\tclean = keep\n"
        try original.write(to: outside, atomically: false, encoding: .utf8)
        let link = box.appendingPathComponent("link.cfg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let shell = Shell(environment: Environment(
            variables: ["GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: box.path))
        shell.sandbox = .rooted(at: box)
        await shell.withCurrent {
            var options = FilterOptions()
            options.file = link.path
            options.skipRepo = true
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await options.uninstall(GitClient(workingDirectory: box))
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == original)
        #expect(try symlinkNames(outside, from: link))
    }

    /// Absolute symlink targets on Windows come back as DOS paths (`D:\...`),
    /// while `URL.path` uses forward slashes. An NT `\??\` prefix or a
    /// leading `/D:` is the same path. Unix stores the destination unchanged.
    private func symlinkNames(_ target: URL, from link: URL) throws -> Bool {
        let stored = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        return Self.samePathSpelling(stored, target.path)
    }

    private static func samePathSpelling(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ path: String) -> String {
            var text = path.replacingOccurrences(of: "\\", with: "/")
            for prefix in ["/??/", "//?/"] where text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                break
            }
            if text.count >= 4 {
                let second = text.index(after: text.startIndex)
                let third = text.index(after: second)
                if text[text.startIndex] == "/", text[third] == ":", text[second].isLetter {
                    text.removeFirst()
                }
            }
            #if os(Windows)
            return text.lowercased()
            #else
            return text
            #endif
        }
        return normalize(lhs) == normalize(rhs)
    }

#if !os(Windows)
    @Test func unixBackslashConfigPathsStayLiteral() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        let root = host.root.appendingPathComponent("SlashName").resolvingSymlinksInPath()
        let outside = host.root.appendingPathComponent("OutsideSlash").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("cfg"), withDestinationURL: outside)
        let literal = root.appendingPathComponent(#"cfg\settings.cfg"#)
        try "[filter \"lfs\"]\n\tclean = literal-file\n".write(
            to: literal, atomically: false, encoding: .utf8)
        let stolen = outside.appendingPathComponent("settings.cfg")
        try "[filter \"lfs\"]\n\tclean = stolen\n".write(to: stolen, atomically: false, encoding: .utf8)
        let included = root.appendingPathComponent(#"cfg\extra.cfg"#)
        try "[filter \"lfs\"]\n\tclean = from-literal\n".write(
            to: included, atomically: false, encoding: .utf8)
        try "[filter \"lfs\"]\n\tclean = stolen-include\n".write(
            to: outside.appendingPathComponent("extra.cfg"), atomically: false, encoding: .utf8)
        let settings = root.appendingPathComponent("settings.cfg")
        // Git config unescapes `\\` to one backslash, the literal filename.
        try "[include]\n\tpath = cfg\\\\extra.cfg\n".write(to: settings, atomically: false, encoding: .utf8)

        let shell = Shell(environment: Environment(
            variables: ["GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: root.path))
        shell.sandbox = .rooted(at: root)
        try await shell.withCurrent {
            var direct = FilterOptions()
            direct.file = literal.path
            direct.skipRepo = true
            let client = GitClient(workingDirectory: root)
            let opened = try await FilterConfiguration.open(direct, client: client)
            #expect(try await opened.value("filter.lfs.clean") == "literal-file")
            try await opened.set("filter.lfs.clean", "updated")
            #expect(try String(contentsOf: literal, encoding: .utf8).contains("updated"))
            #expect(try String(contentsOf: stolen, encoding: .utf8) == "[filter \"lfs\"]\n\tclean = stolen\n")
            var includedOptions = FilterOptions()
            includedOptions.file = settings.path
            includedOptions.skipRepo = true
            let config = try await FilterConfiguration.open(includedOptions, client: client)
            #expect(try await config.value("filter.lfs.clean") == "from-literal")
        }
    }
#endif

}
