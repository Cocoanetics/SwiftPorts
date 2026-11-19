import Foundation
import Testing
import SwiftGit
import ShellKit
@testable import GitLFSKit

@Suite("LFS config sources")
struct LFSConfigSourceTests {
    let host = IsolatedLFSHost()

    @Test("access mode, including private and the URL with its user stripped")
    func access() async throws {
        try await host.run {
            let made = try await LFSFixture.make(
                host, "access", remotes: [("origin", "https://example.com/repo.git")])
            let url = "https://example.com/repo.git/info/lfs"
            let modes = [
                ("basic", "basic"), ("BASIC", "basic"), ("private", "basic"),
                ("negotiate", "negotiate"), ("invalidauth", "invalidauth")
            ]
            for (raw, mode) in modes {
                try await made.client.configSet("lfs.\(url).access", raw)
                let finder = await LFSEndpointFinder(made.client)
                #expect(finder.access(for: url).mode == mode, "\(raw)")
            }
            let authed = "https://git:secret@example.com/repo.git/info/lfs"
            let finder = await LFSEndpointFinder(made.client)
            #expect(finder.access(for: authed).url == url)
            #expect(finder.access(for: authed).mode == "invalidauth")

            await finder.setAccess(LFSAccess(mode: "basic", url: url))
            #expect(finder.access(for: url).mode == "basic")
            #expect(try await made.client.configGet("lfs.\(url).access") == "basic")
            await finder.setAccess(LFSAccess(mode: "none", url: url))
            #expect(finder.access(for: url).mode == "none")
            #expect(try await made.client.configGet("lfs.\(url).access") == nil)

            let untouched = await LFSEndpointFinder(made.client)
            #expect(untouched.access(for: url).mode == "none")
        }
    }

    @Test("bool spells true, 1, on, yes and t; anything else is false")
    func boolValues() {
        #expect(LFSConfiguration.bool("yes", fallback: false))
        #expect(LFSConfiguration.bool("t", fallback: false))
        #expect(!LFSConfiguration.bool("false", fallback: true))
        #expect(!LFSConfiguration.bool("0", fallback: true))
        #expect(LFSConfiguration.bool(nil, fallback: true))
        #expect(LFSConfiguration.bool("", fallback: false) == false)
    }

    @Test("remote selection, searchall, and git lfs env's Endpoint lines")
    func remotes() async throws {
        try await host.run {
            let tracked = try await LFSFixture.make(
                host, "tracked",
                remotes: [("origin", "https://example.com/o.git"), ("upstream", "https://example.com/u.git")],
                config: [("branch.main.remote", "upstream"), ("branch.main.pushremote", "origin")],
                commit: true)
            let branch = await LFSEndpointFinder(tracked.client)
            #expect(await branch.downloadRemote() == "upstream")
            #expect(branch.uploadRemote() == "origin")
            let lines = branch.environmentEndpoints()
            #expect(lines["Endpoint"] == nil)
            #expect(lines["Endpoint (origin)"]?.hasPrefix("https://example.com/o.git/info/lfs ") == true)
            #expect(lines["Endpoint (upstream)"]?.hasPrefix("https://example.com/u.git/info/lfs ") == true)

            let defaults = try await LFSFixture.make(
                host, "defaults",
                remotes: [("origin", "https://example.com/o.git"), ("upstream", "https://example.com/u.git")],
                config: [("remote.lfsdefault", "upstream"), ("remote.lfspushdefault", "origin")],
                commit: true)
            let def = await LFSEndpointFinder(defaults.client)
            #expect(await def.downloadRemote() == "upstream")
            #expect(def.uploadRemote() == "origin")

            let pushDefault = try await LFSFixture.make(
                host, "push-default",
                remotes: [("origin", "https://example.com/o.git"), ("other", "https://example.com/o2.git")],
                config: [("remote.pushdefault", "other")],
                commit: true)
            let pushed = await LFSEndpointFinder(pushDefault.client)
            #expect(await pushed.downloadRemote() == "origin")
            #expect(pushed.uploadRemote() == "other")

            let only = try await LFSFixture.make(
                host, "only", remotes: [("upstream", "https://example.com/u.git")], commit: true)
            let single = await LFSEndpointFinder(only.client)
            #expect(await single.downloadRemote() == "upstream")
            #expect(single.environmentEndpoints()["Endpoint"] == nil)
            #expect(single.environmentEndpoints()["Endpoint (upstream)"] != nil)

            let originOnly = try await LFSFixture.make(
                host, "origin-only", remotes: [("origin", "https://example.com/repo.git")])
            let env = await LFSEndpointFinder(originOnly.client).environmentEndpoints()
            #expect(env == ["Endpoint": "https://example.com/repo.git/info/lfs (auth=none)"])

            let search = try await LFSFixture.make(
                host, "search",
                remotes: [("origin", "https://example.com/o.git"), ("upstream", "https://example.com/u.git")],
                config: [("lfs.remote.searchall", "true")],
                commit: true)
            let candidates = await LFSEndpointFinder(search.client).candidateRemotes(operation: "download")
            #expect(candidates == ["origin", "upstream"])
        }
    }

    @Test("autodetect follows a remote-tracking branch that contains HEAD")
    func autodetect() async throws {
        try await host.run {
            let made = try await LFSFixture.make(
                host, "auto",
                remotes: [("origin", "https://example.com/o.git"), ("upstream", "https://example.com/u.git")],
                config: [("branch.main.remote", "upstream"), ("lfs.remote.autodetect", "true")],
                commit: true)
            let head = try await made.client.resolveOID("HEAD")
            let gitDir = try #require(try await made.client.gitDir())
            let ref = URL(fileURLWithPath: gitDir).appendingPathComponent("refs/remotes/origin/main")
            try FileManager.default.createDirectory(
                at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (head + "\n").write(to: ref, atomically: true, encoding: .utf8)

            let finder = await LFSEndpointFinder(made.client)
            #expect(await finder.downloadRemote() == "origin")
            #expect(finder.uploadRemote() == "upstream")
            #expect(finder.environmentEndpoints()["Endpoint"] == nil)
        }
    }

    @Test("FETCH_HEAD fills in a missing origin URL")
    func fetchHead() async throws {
        try await host.run {
            let made = try await LFSFixture.make(host, "fetch", commit: true)
            let gitDir = try #require(try await made.client.gitDir())
            let oid = String(repeating: "a", count: 40)
            let text = "\(oid)\t\tbranch 'main' of https://example.com/from-fetch\n"
            try text.write(
                to: URL(fileURLWithPath: gitDir).appendingPathComponent("FETCH_HEAD"),
                atomically: true, encoding: .utf8)
            let finder = await LFSEndpointFinder(made.client)
            #expect(finder.endpoint(operation: "download").url
                    == "https://example.com/from-fetch.git/info/lfs")
        }
    }

    @Test("a local repository remote becomes file:// and is not given /info/lfs")
    func localPath() async throws {
        try await host.run {
            let made = try await LFSFixture.make(host, "local", commit: true)
            try await made.client.configSet("remote.origin.url", made.directory.path)
            let url = await LFSEndpointFinder(made.client).endpoint(operation: "download").url
            #expect(url.hasPrefix("file://"))
            #expect(url.hasSuffix("/.git"))
            #expect(!url.contains("info/lfs"))
        }
    }

    @Test("a relative local URL resolves against the repository directory")
    func relativeLocalURL() async throws {
        try await host.run {
            let made = try await LFSFixture.make(host, "rel", commit: true)
            let server = made.directory.deletingLastPathComponent()
                .appendingPathComponent("server.git", isDirectory: true)
            try await GitClient(workingDirectory: server).initRepository(initialBranch: "main")
            let wanted = "file://\(server.path)/.git"
            try await made.client.configSet("remote.origin.url", "../server.git")
            let remote = await LFSEndpointFinder(made.client).endpoint(operation: "download").url
            #expect(remote == wanted)
            try await made.client.configSet("lfs.url", "../server.git")
            let configured = await LFSEndpointFinder(made.client).endpoint(operation: "download").url
            #expect(configured == wanted)
        }
    }

    @Test("a denied FETCH_HEAD does not choose the endpoint")
    func deniedFetchHead() async throws {
        let directory = try await host.run {
            let made = try await LFSFixture.make(host, "fetch-deny", commit: true)
            let gitDir = try #require(try await made.client.gitDir())
            let oid = String(repeating: "b", count: 40)
            let text = "\(oid)\t\tbranch 'main' of https://example.com/denied-fetch\n"
            try text.write(
                to: URL(fileURLWithPath: gitDir).appendingPathComponent("FETCH_HEAD"),
                atomically: true, encoding: .utf8)
            return made.directory
        }
        let shell = Shell(
            environment: Environment(variables: host.variables, workingDirectory: host.root.path),
            sandbox: host.sandbox { $0.lastPathComponent == "FETCH_HEAD" })
        let url = await shell.withCurrent {
            let client = GitClient(workingDirectory: directory)
            return await LFSEndpointFinder(client).endpoint(operation: "download").url
        }
        #expect(url.isEmpty)
    }

    @Test(".lfsconfig is read from the index, then HEAD; a bare repo reads HEAD only")
    func lfsconfigFallback() async throws {
        try await host.run {
            let made = try await LFSFixture.make(host, "fallback", commit: true)
            let file = made.directory.appendingPathComponent(".lfsconfig")
            try Data("[lfs]\n\turl = https://head.example/repo\n".utf8).write(to: file)
            try await made.client.add(paths: [".lfsconfig"])
            _ = try await made.client.commit(message: "lfsconfig", author: nil, allowEmpty: false)
            try Data("[lfs]\n\turl = https://index.example/repo\n".utf8).write(to: file)
            try await made.client.add(paths: [".lfsconfig"])
            try FileManager.default.removeItem(at: file)

            let bare = host.root.appendingPathComponent(IsolatedLFSHost.shortName("bare"), isDirectory: true)
            try FileManager.default.copyItem(at: made.directory.appendingPathComponent(".git"), to: bare)
            // A copied `.git` still says `bare = false`, so git-lfs's
            // `rev-parse --is-bare-repository` would keep reading the index.
            let configFile = bare.appendingPathComponent("config")
            var configText = try String(contentsOf: configFile, encoding: .utf8)
            configText = configText.replacingOccurrences(of: "bare = false", with: "bare = true")
            try configText.write(to: configFile, atomically: true, encoding: .utf8)

            let indexed = await LFSEndpointFinder(made.client)
            #expect(indexed.endpoint(operation: "download").url == "https://index.example/repo")

            let bareFinder = await LFSEndpointFinder(GitClient(workingDirectory: bare))
            #expect(bareFinder.endpoint(operation: "download").url == "https://head.example/repo")

            try await made.client.remove(paths: [".lfsconfig"], keepWorktree: false, force: true)
            let head = await LFSEndpointFinder(made.client)
            #expect(head.endpoint(operation: "download").url == "https://head.example/repo")
        }
    }

    @Test("a .lfsconfig git cannot parse drops git config too")
    func badLFSConfig() async throws {
        try await host.run {
            let made = try await LFSFixture.make(
                host, "bad",
                remotes: [("origin", "https://example.com/repo.git")],
                lfsconfig: "=\n")
            let finder = await LFSEndpointFinder(made.client)
            #expect(finder.endpoint(operation: "download").url == "origin.git/info/lfs")
        }
    }

    @Test("a URL-specific extraHeader wins over http.extraheader")
    func extraHeader() async throws {
        try await host.run {
            let made = try await LFSFixture.make(
                host, "header",
                remotes: [("origin", "https://example.com/repo.git")],
                config: [
                    ("http.extraheader", "X-Base: base"),
                    ("http.https://example.com.extraheader", "X-Host: host")
                ])
            let headers = await LFSEndpointFinder(made.client)
                .extraHeaders(for: "https://example.com/repo.git/info/lfs/objects/batch")
            #expect(headers.contains { $0.name == "X-Host" && $0.value == "host" })
            #expect(!headers.contains { $0.name == "X-Base" })
        }
    }

    @Test("netrc finds a machine, then default, and rejects a machine after default")
    func netrc() throws {
        let file = try NetrcFile.parse("""
        machine example.com
        login git
        password secret

        machine example.com
        login other
        password other-secret

        default
        login any
        password fallback
        """)
        #expect(file.find(host: "example.com", login: "")?.password == "secret")
        #expect(file.find(host: "example.com", login: "other")?.password == "other-secret")
        #expect(file.find(host: "elsewhere", login: "nope")?.password == "fallback")
        #expect(NetrcHost.name(of: "example.com:8443") == "example.com")
        #expect(throws: NetrcFile.ParseError.self) {
            try NetrcFile.parse("default\nlogin a\npassword b\nmachine h\nlogin g\npassword p\n")
        }
    }
}
