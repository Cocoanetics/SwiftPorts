import Foundation
import Testing
import SwiftGit
import ShellKit
@testable import GitLFSKit

@Suite("LFS env report")
struct LFSEnvReportTests {
    let host = IsolatedLFSHost()

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
            let expected = """
            \(LFSVersion.string)
            \(PortVersion.gitLine)

            LocalWorkingDir=\(root)
            LocalGitDir=\(root)/.git
            LocalGitStorageDir=\(root)/.git
            LocalMediaDir=\(root)/.git/lfs/objects
            LocalReferenceDirs=
            TempDir=\(root)/.git/lfs/tmp
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
            LfsStorageDir=\(root)/.git/lfs
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
            for storage in ["../store", host.root.appendingPathComponent("absolute").path] {
                try await made.client.configSet("lfs.storage", storage)
                let config = await LFSConfiguration.load(made.client)
                let paths = await LFSRepositoryPaths.load(made.client, configuration: config)
                let expected = storage.hasPrefix("/") ? storage
                    : LFSRepositoryPaths.canonical(made.directory.path) + "/store"
                #expect(paths.storage == expected)
                #expect(paths.git == common && paths.common == common)
            }
            let linked = host.root.appendingPathComponent("linked")
            try await made.client.worktreeAdd(path: linked, branch: "linked")
            let worktree = GitClient(workingDirectory: linked)
            let config = await LFSConfiguration.load(worktree)
            let paths = await LFSRepositoryPaths.load(worktree, configuration: config)
            #expect(paths.working == LFSRepositoryPaths.canonical(linked.path))
            #expect(paths.git == common + "/worktrees/linked")
            #expect(paths.common == common)
            let outside = await LFSEnv.run(client: GitClient(workingDirectory: host.home))
            #expect(outside.status == 0)
            #expect(outside.stdout.contains(
                "LocalWorkingDir=\nLocalGitDir=\nLocalGitStorageDir=\nLocalMediaDir=lfs/objects\n"))
            #expect(outside.stdout.contains("TempDir=lfs/tmp\n"))
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
            Shell.current.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = objectPath
            let alternates = made.directory.appendingPathComponent(".git/objects/info/alternates")
            try Data("\n# ignored\n\(objectPath.goQuoted)\n/missing/objects\n".utf8).write(to: alternates)
            let config = await LFSConfiguration.load(made.client)
            let paths = await LFSRepositoryPaths.load(made.client, configuration: config)
            #expect(paths.references == [media.path, media.path])
            let report = await LFSEnv.run(client: made.client)
            #expect(report.stdout.contains("LocalReferenceDirs=\(media.path), \(media.path)\n"))
            #expect(report.stdout.contains("GIT_ALTERNATE_OBJECT_DIRECTORIES=\(objectPath)\n"))
            Shell.current.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = nil
            let bare = GitClient(workingDirectory: host.root.appendingPathComponent("bare"))
            try await bare.initRepository(bare: true, initialBranch: "main")
            let barePaths = await LFSRepositoryPaths.load(bare, configuration: await LFSConfiguration.load(bare))
            #expect(barePaths.working.isEmpty)
            #expect(barePaths.git == LFSRepositoryPaths.canonical(bare.workingDirectory.path))
            #expect(barePaths.common == barePaths.git)
            #expect(barePaths.storage == barePaths.git + "/lfs")
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
            Shell.current.environment["GIT_SHELL_ONLY"] = "original/../value"
            let entries = LFSEnvironment.gitEntries()
            #expect(entries.contains("GIT_SHELL_ONLY=original/../value"))
            #expect(Set(entries.map { String($0.prefix(while: { $0 != "=" })) }) ==
                Set(Shell.current.environment.variables.keys.filter { $0.hasPrefix("GIT_") }))
        }
    }
}
