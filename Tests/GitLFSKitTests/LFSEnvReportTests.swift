import Foundation
import Testing
import SwiftGit
import ShellKit
@testable import GitLFSKit

@Suite("LFS env report")
struct LFSEnvReportTests {
    let host = IsolatedLFSHost()

    /// Go's filepath.Join uses the host separator, including for relative paths.
    private func nativePath(_ path: String) -> String {
        #if os(Windows)
        path.replacingOccurrences(of: "/", with: "\\")
        #else
        path
        #endif
    }

    @Test func integers() {
        for text in [" 8", "8 ", "8k", "1.0", "0x10", "", "--1", "١", "999999999999999999999"] {
            #expect(LFSConfiguration.integer(text, fallback: 7) == 7, "\(text)")
        }
        #expect(LFSConfiguration.integer("+12", fallback: 7) == 12)
        #expect(LFSConfiguration.integer("-2", fallback: 7) == -2)
        #expect(LFSConfiguration.integer("0", fallback: 7) == 0)
    }

    @Test func defaultsAndOrder() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-defaults")
            let result = await LFSEnv.run(client: made.client)
            let root = LFSRepositoryPaths.canonical(made.directory.path)
            let git = nativePath(root + "/.git")
            let storage = nativePath(git + "/lfs")
            let expected = """
            \(LFSVersion.string)
            \(PortVersion.gitLine)

            LocalWorkingDir=\(root)
            LocalGitDir=\(git)
            LocalGitStorageDir=\(git)
            LocalMediaDir=\(nativePath(storage + "/objects"))
            LocalReferenceDirs=
            TempDir=\(nativePath(storage + "/tmp"))
            ConcurrentTransfers=8
            TusTransfers=false
            BasicTransfersOnly=false
            SkipDownloadErrors=false
            FetchRecentAlways=false
            FetchRecentRefsDays=7
            FetchRecentCommitsDays=0
            FetchRecentRefsIncludeRemotes=true
            PruneOffsetDays=3
            PruneVerifyRemoteAlways=false
            PruneVerifyUnreachableAlways=false
            PruneRemoteName=origin
            LfsStorageDir=\(storage)
            AccessDownload=none
            AccessUpload=none
            DownloadTransfers=basic,lfs-standalone-file,ssh
            UploadTransfers=basic,lfs-standalone-file,ssh
            """ + "\n" + LFSEnvironment.gitEntries().joined(separator: "\n") + "\n" + """
            git config filter.lfs.process = ""
            git config filter.lfs.smudge = ""
            git config filter.lfs.clean = ""
            """ + "\n"
            #expect(result.stdout == expected)
            #expect(result.stderr.isEmpty && result.status == 0)
        }
    }

    @Test func settingsAndTransfers() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-settings", config: [
                ("lfs.tustransfers", "YES"), ("lfs.skipdownloaderrors", "true"),
                ("lfs.customtransfer.zeta.path", ""), ("lfs.customtransfer.zeta.direction", "UPLOAD"),
                ("lfs.customtransfer.alpha.path", "unused"), ("lfs.customtransfer.alpha.direction", "download"),
                ("lfs.customtransfer.shared.path", "unused"),
                ("lfs.customtransfer.ignored.path", "unused"), ("lfs.customtransfer.ignored.direction", "bad"),
                ("lfs.fetchinclude", " foo/, bar\\, ,baz// "), ("lfs.fetchexclude", "   "),
                ("lfs.extension.zip.priority", "4"), ("lfs.extension.zip.clean", "unused"),
                ("lfs.fetchrecentremoterefs", "no"), ("lfs.concurrenttransfers", " 9"),
                ("filter.lfs.process", "quotes \" and \\ and\ttab\nnewline")
            ])
            let config = await LFSConfiguration.load(made.client)
            #expect(LFSTransferListing.names(config, upload: false) == "alpha,basic,lfs-standalone-file,shared,ssh")
            #expect(LFSTransferListing.names(config, upload: true) == "basic,lfs-standalone-file,shared,ssh,tus,zeta")
            #expect(config.extensionLines == ["Extension[4]=zip"])
            #expect(config.fetchPaths("lfs.fetchinclude") == ["foo", "bar", "", "baz/"])
            #expect(config.fetchPaths("lfs.fetchexclude").isEmpty)
            for value in ["false", "", "0", "yes"] {
                Shell.current.environment["GIT_LFS_SKIP_DOWNLOAD_ERRORS"] = value
                #expect(config.skipDownloadErrors)
            }
            try await made.client.configSet("lfs.skipdownloaderrors", "false")
            let disabled = await LFSConfiguration.load(made.client)
            Shell.current.environment["GIT_LFS_SKIP_DOWNLOAD_ERRORS"] = "false"
            #expect(!disabled.skipDownloadErrors)
            Shell.current.environment["GIT_LFS_SKIP_DOWNLOAD_ERRORS"] = "yes"
            #expect(disabled.skipDownloadErrors)
            let report = await LFSEnv.run(client: made.client).stdout
            #expect(report.contains("ConcurrentTransfers=8\n"))
            #expect(report.contains("FetchRecentRefsIncludeRemotes=false\n"))
            #expect(report.contains("FetchInclude=foo, bar, , baz/\nExtension[4]=zip\n"))
            #expect(!report.contains("FetchExclude="))
            #expect(report.contains("git config filter.lfs.process = \"quotes \\\" and \\\\ and\\ttab\"\n"))
            try await made.client.configSet("lfs.basictransfersonly", "on")
            let basic = await LFSConfiguration.load(made.client)
            #expect(LFSTransferListing.names(basic, upload: false) == "basic")
            #expect(LFSTransferListing.names(basic, upload: true) == "basic")
        }
    }

    @Test func orderedEndpointsAndAccess() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-remotes", remotes: [
                ("zebra", "git@example.com:team/z.git"), ("origin", "https://example.com/o.git"),
                ("alpha", "https://example.com/a.git")
            ], config: [
                ("branch.main.remote", "zebra"), ("branch.main.pushremote", "alpha"),
                ("lfs.https://example.com/team/z.git/info/lfs.access", "private"),
                ("lfs.https://example.com/a.git/info/lfs.access", "negotiate")
            ], commit: true)
            let finder = await LFSEndpointFinder(made.client)
            #expect(finder.environmentReport().map(\.key) == [
                "Endpoint (zebra)", "Endpoint (origin)", "Endpoint (alpha)"
            ])
            let result = await LFSEnv.run(client: made.client)
            #expect(result.stdout.contains("Endpoint (zebra)=https://example.com/team/z.git/info/lfs (auth=basic)\n"
                + "  SSH=git@example.com:team/z.git\nEndpoint (origin)="))
            #expect(result.stdout.contains("AccessDownload=basic\nAccessUpload=negotiate\n"))
        }
    }

    @Test func pathsWithoutOracle() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-paths", commit: true)
            let common = LFSRepositoryPaths.canonical(made.directory.appendingPathComponent(".git").path)
            let absolute = host.root.appendingPathComponent("absolute").path
            let relative = nativePath(LFSRepositoryPaths.canonical(made.directory.path) + "/store")
            for (storage, expected) in [("../store", relative), (absolute, absolute)] {
                try await made.client.configSet("lfs.storage", storage)
                let config = await LFSConfiguration.load(made.client)
                let paths = await LFSRepositoryPaths.load(made.client, configuration: config)
                #expect(paths.storage == expected)
                #expect(paths.git == common && paths.common == common)
            }
            let linked = host.root.appendingPathComponent("linked")
            try await made.client.worktreeAdd(path: linked, branch: "linked")
            let worktree = GitClient(workingDirectory: linked)
            let config = await LFSConfiguration.load(worktree)
            let paths = await LFSRepositoryPaths.load(worktree, configuration: config)
            #expect(paths.working == LFSRepositoryPaths.canonical(linked.path))
            #expect(paths.git == nativePath(common + "/worktrees/linked"))
            #expect(paths.common == common)
            let insideGit = GitClient(workingDirectory: made.directory.appendingPathComponent(".git/objects"))
            let insidePaths = await LFSRepositoryPaths.load(
                insideGit, configuration: await LFSConfiguration.load(insideGit))
            #expect(insidePaths.working.isEmpty)
            #expect(insidePaths.git == common)
            let outside = await LFSEnv.run(client: GitClient(workingDirectory: host.home))
            #expect(outside.status == 0)
            #expect(outside.stdout.contains(
                "LocalWorkingDir=\nLocalGitDir=\nLocalGitStorageDir=\nLocalMediaDir=\(nativePath("lfs/objects"))\n"))
            #expect(outside.stdout.contains("TempDir=\(nativePath("lfs/tmp"))\n"))
            let outsideClient = GitClient(workingDirectory: host.home)
            for (storage, expectedStorage, expectedMedia, expectedTemporary) in [
                ("../cache", nativePath("../cache"), nativePath("../cache/objects"), nativePath("../cache/tmp")),
                (".", ".", nativePath("objects"), nativePath("tmp"))
            ] {
                try await outsideClient.configSet("lfs.storage", storage, scope: .global)
                let paths = await LFSRepositoryPaths.load(
                    outsideClient, configuration: await LFSConfiguration.load(outsideClient))
                #expect(paths.storage == expectedStorage)
                #expect(paths.media == expectedMedia)
                #expect(paths.temporary == expectedTemporary)
            }
        }
    }

    @Test func referencesAndBareWithoutOracle() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-references")
            let reference = host.root.appendingPathComponent("reference")
            let media = reference.appendingPathComponent("lfs/objects")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let objectPath = reference.appendingPathComponent("objects").path
            Shell.current.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = "../reference/objects"
            let relativePaths = await LFSRepositoryPaths.load(
                made.client, configuration: await LFSConfiguration.load(made.client))
            #expect(relativePaths.references == [nativePath("../reference/lfs/objects")])
            Shell.current.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = objectPath
            let alternates = made.directory.appendingPathComponent(".git/objects/info/alternates")
            try Data("\n# ignored\n\(objectPath.goQuoted)\n/missing/objects\n".utf8).write(to: alternates)
            let config = await LFSConfiguration.load(made.client)
            let paths = await LFSRepositoryPaths.load(made.client, configuration: config)
            let referencePath = nativePath(media.path)
            #expect(paths.references == [referencePath, referencePath])
            let report = await LFSEnv.run(client: made.client)
            #expect(report.stdout.contains("LocalReferenceDirs=\(referencePath), \(referencePath)\n"))
            #expect(report.stdout.contains("GIT_ALTERNATE_OBJECT_DIRECTORIES=\(objectPath)\n"))
            Shell.current.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = nil
            let bare = GitClient(workingDirectory: host.root.appendingPathComponent("bare"))
            try await bare.initRepository(bare: true, initialBranch: "main")
            let barePaths = await LFSRepositoryPaths.load(bare, configuration: await LFSConfiguration.load(bare))
            #expect(barePaths.working.isEmpty)
            #expect(barePaths.git == LFSRepositoryPaths.canonical(bare.workingDirectory.path))
            #expect(barePaths.common == barePaths.git)
            #expect(barePaths.storage == nativePath(barePaths.git + "/lfs"))
        }
    }

    @Test func mergedSafeConfiguration() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let made = try await LFSFixture.make(host, "env-safe", config: [
                ("lfs.fetchinclude", "from-git/"), ("lfs.concurrenttransfers", "5")
            ], lfsconfig: """
            [lfs]
              fetchinclude = from-file/
              fetchexclude = cache/
              concurrenttransfers = 99
            [lfs "extension.zip"]
              priority = 7
            """)
            let config = await LFSConfiguration.load(made.client)
            #expect(config.integer("lfs.concurrenttransfers", fallback: 8) == 5)
            #expect(config.fetchPaths("lfs.fetchinclude") == ["from-git"])
            #expect(config.fetchPaths("lfs.fetchexclude") == ["cache"])
            #expect(config.extensionLines == ["Extension[7]=zip"])
            try await made.client.configSet("lfs.concurrenttransfers", "6", scope: .global)
            let error = OutputSink()
            Shell.current.stderr = error
            let report = await LFSEnv.run(client: made.client)
            error.finish()
            let warning = await error.readAllString()
            #expect(report.stdout.contains("ConcurrentTransfers=5\n"))
            #expect(warning.contains("warning: These `git config` values clash:\n"))
            #expect(warning.contains("git config \"lfs.concurrenttransfers\""))
            Shell.current.environment["GIT_SHELL_ONLY"] = "original/../value"
            let entries = LFSEnvironment.gitEntries()
            #expect(entries.contains("GIT_SHELL_ONLY=original/../value"))
            #expect(Set(entries.map { String($0.prefix(while: { $0 != "=" })) }) ==
                Set(Shell.current.environment.variables.keys.filter { $0.hasPrefix("GIT_") }))
        }
    }
}
