import Foundation
import GitLFSTestSupport
import ShellKit
import SwiftGit
import Testing
@testable import GitLFSKit
#if os(Windows)
import WinSDK
#endif

extension LFSFilterTests {
    @Suite("LFS checkout and pull SDK (git-lfs 3.7.1)")
    struct LFSCheckoutPullTests {
        private let alpha = Data("alpha-lfs-content\n".utf8)
        private let beta = Data("beta-lfs-content\n".utf8)
        private let gamma = Data("gamma-lfs-content\n".utf8)

        private func oid(_ data: Data) -> String { LFSServerRepository.oid(data) }

        private func runCheckout(
            _ options: CheckoutOptions = CheckoutOptions(), arguments: [String] = [],
            client: LFSClient, git: GitClient, terminal: Bool = false
        ) async throws -> LFSCommandResult {
            let streamed = TransferTestLock("")
            var environment = LFSTransferEnvironment()
            environment.stdout = { text in streamed.withLock { $0 += text } }
            var result = try await options.run(
                arguments, client: client, git: git, terminal: terminal, environment: environment)
            result.stdout = streamed.withLock { $0 } + result.stdout
            return result
        }

        private func runPull(
            _ options: PullOptions = PullOptions(), arguments: [String] = [],
            client: LFSClient, git: GitClient, terminal: Bool = false
        ) async throws -> LFSCommandResult {
            let streamed = TransferTestLock("")
            var environment = LFSTransferEnvironment()
            environment.stdout = { text in streamed.withLock { $0 += text } }
            var result = try await options.run(
                arguments, client: client, git: git, terminal: terminal, environment: environment)
            result.stdout = streamed.withLock { $0 } + result.stdout
            return result
        }

        private func commitTracked(
            _ repo: LFSServerRepository, files: [(String, Data)], pattern: String = "*.dat"
        ) async throws {
            try Data("\(pattern) filter=lfs diff=lfs merge=lfs -text\n".utf8)
                .write(to: repo.directory.appendingPathComponent(".gitattributes"))
            try await repo.commit(files, message: "tracked pointers")
        }

        @Test("checkout restores local objects, refreshes the index, and never contacts the server")
        func checkoutRefreshesIndexAndNeverDownloads() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                server.store(beta, oid: oid(beta))
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha), ("sub/b.dat", beta)])
                    try await repo.storeLocally(alpha)
                    try await repo.storeLocally(beta)

                    let result = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stderr.isEmpty)
                    #expect(result.stdout == "Checking out LFS objects: 100% (2/2), 35 B | 0 B/s, done.\n")
                    #expect(server.requests().isEmpty)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("a.dat")) == alpha)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("sub/b.dat")) == beta)
                    #expect(try await repo.git.status().isClean)
                }
            }
        }

        @Test("checkout preserves modified files, different pointers, staged deletions, and directory conflicts")
        func checkoutPreservesModifiedAndSkipsUnsafePaths() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(
                        repo,
                        files: [
                            ("mod.dat", alpha),
                            ("otherptr.dat", alpha),
                            ("deleted.dat", beta),
                            ("dir1/nested.dat", gamma)
                        ])
                    for data in [alpha, beta, gamma] { try await repo.storeLocally(data) }

                    let modified = Data("locally edited non-pointer\n".utf8)
                    try modified.write(to: repo.directory.appendingPathComponent("mod.dat"))
                    let otherPtr = Data(Pointer(oid: oid(beta), size: Int64(beta.count)).encoded.utf8)
                    try otherPtr.write(to: repo.directory.appendingPathComponent("otherptr.dat"))
                    try await repo.git.remove(paths: ["deleted.dat"], force: true)
                    try FileManager.default.removeItem(at: repo.directory.appendingPathComponent("dir1"))
                    try Data("file blocking dir1\n".utf8).write(to: repo.directory.appendingPathComponent("dir1"))

                    let result = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("mod.dat")) == modified)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("otherptr.dat")) == otherPtr)
                    #expect(!FileManager.default.fileExists(
                        atPath: repo.directory.appendingPathComponent("deleted.dat").path))
                    #expect(result.stderr.contains("\"dir1/nested.dat\": not a directory"))
                }
            }
        }

        @Test("checkout with missing local object writes pointer placeholder and reports skip")
        func checkoutMissingLocalObject() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha)])
                    try FileManager.default.removeItem(at: repo.directory.appendingPathComponent("a.dat"))

                    let result = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stderr
                        == "Skipped checkout for \"a.dat\", content not local. Use fetch to download.\n")
                    #expect(server.requests().isEmpty)
                    let pointer = Pointer(oid: oid(alpha), size: Int64(alpha.count)).encoded
                    #expect(try String(contentsOf: repo.directory.appendingPathComponent("a.dat"), encoding: .utf8)
                        == pointer)
                }
            }
        }

        @Test("checkout preserves read-only mode, breaks hard links, and preserves empty file mtime")
        func checkoutPermissionsHardLinksAndEmptyMtime() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    let empty = Data()
                    try await commitTracked(repo, files: [("ro.dat", alpha), ("link.dat", beta), ("empty.dat", empty)])
                    try await repo.storeLocally(alpha)
                    try await repo.storeLocally(beta)

                    let roFile = repo.directory.appendingPathComponent("ro.dat")
                    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: roFile.path)

                    let external = repo.directory.deletingLastPathComponent().appendingPathComponent("hardlink-source")
                    let linkFile = repo.directory.appendingPathComponent("link.dat")
                    let linkPointer = try Data(contentsOf: linkFile)
                    try linkPointer.write(to: external)
                    try FileManager.default.removeItem(at: linkFile)
                    // `FileManager.linkItem` creates a symbolic link on Windows.
                    // Checkout rejects that as "not a regular file". A hard link
                    // is what git-lfs replaces without rewriting the other name.
                    try linkHard(from: external, to: linkFile)

                    let emptyFile = repo.directory.appendingPathComponent("empty.dat")
                    let pastDate = Date(timeIntervalSince1970: 1_700_000_000)
                    try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: emptyFile.path)
                    let beforeAttrs = try FileManager.default.attributesOfItem(atPath: emptyFile.path)
                    let beforeMtime = beforeAttrs[.modificationDate] as? Date

                    let result = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stderr.isEmpty)
                    #expect(try Data(contentsOf: roFile) == alpha)
                    #if !os(Windows)
                    let perms = (try FileManager.default.attributesOfItem(atPath: roFile.path)[.posixPermissions]
                        as? NSNumber)?.intValue
                    #expect(perms == 0o444)
                    #endif
                    #expect(try Data(contentsOf: linkFile) == beta)
                    #expect(try Data(contentsOf: external) == linkPointer)
                    let afterAttrs = try FileManager.default.attributesOfItem(atPath: emptyFile.path)
                    let afterMtime = afterAttrs[.modificationDate] as? Date
                    #expect(afterMtime == beforeMtime)
                }
            }
        }

        /// Another directory entry for `source`. On Windows this is
        /// `CreateHardLinkW`; `FileManager.linkItem` is a symbolic link there.
        private func linkHard(from source: URL, to link: URL) throws {
            #if os(Windows)
            let created = source.path.withCString(encodedAs: UTF16.self) { existing in
                link.path.withCString(encodedAs: UTF16.self) { name in
                    CreateHardLinkW(name, existing, nil)
                }
            }
            guard created else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: link.path])
            }
            #else
            try FileManager.default.linkItem(at: source, to: link)
            #endif
        }

        @Test("checkout conflict stages and argument validation match git-lfs 3.7.1")
        func checkoutConflictValidationAndStages() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha)])
                    try await repo.storeLocally(alpha)

                    var both = CheckoutOptions(); both.ours = true; both.theirs = true; both.to = "out.dat"
                    let r1 = try await runCheckout(both, arguments: ["a.dat"], client: repo.client, git: repo.git)
                    #expect(r1.status == 2)
                    #expect(r1.stderr == "Error parsing args: at most one of --base, --theirs, and --ours is allowed\n")

                    var toOnly = CheckoutOptions(); toOnly.to = "out.dat"
                    let r2 = try await runCheckout(toOnly, arguments: ["a.dat"], client: repo.client, git: repo.git)
                    #expect(r2.status == 2)
                    #expect(r2.stderr == "--to and exactly one of --theirs, --ours, and --base must be used together\n")

                    var baseOnly = CheckoutOptions(); baseOnly.base = true
                    let r3 = try await runCheckout(baseOnly, arguments: ["a.dat"], client: repo.client, git: repo.git)
                    #expect(r3.status == 2)
                    #expect(r3.stderr == "--to and exactly one of --theirs, --ours, and --base must be used together\n")

                    var missingPath = CheckoutOptions(); missingPath.base = true; missingPath.to = "out.dat"
                    let r4 = try await runCheckout(missingPath, arguments: [], client: repo.client, git: repo.git)
                    #expect(r4.status == 2)
                    #expect(r4.stderr == "--to requires exactly one Git LFS object file path\n")

                    let r5 = try await runCheckout(missingPath, arguments: ["a.dat", "b.dat"],
                                                   client: repo.client, git: repo.git)
                    #expect(r5.status == 2)
                    #expect(r5.stderr == "--to requires exactly one Git LFS object file path\n")

                    let notMerging = try await runCheckout(missingPath, arguments: ["a.dat"],
                                                           client: repo.client, git: repo.git)
                    #expect(notMerging.status == 2)
                    #expect(notMerging.stderr == "Could not checkout (are you not in the middle of a merge?): "
                        + "Git can't resolve ref: \":1:a.dat\"\n")
                }
            }
        }

        @Test("checkout subdirectory globs and dot/parent patterns")
        func checkoutSubdirectoryGlobs() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("top.dat", alpha), ("sub/nested.dat", beta)])
                    try await repo.storeLocally(alpha)
                    try await repo.storeLocally(beta)

                    let subDir = repo.directory.appendingPathComponent("sub")
                    let subGit = GitClient(workingDirectory: subDir)
                    let subClient = await LFSClient(git: subGit, configuration: .ephemeral)

                    let r1 = try await runCheckout(arguments: ["."], client: subClient, git: subGit)
                    #expect(r1.status == 0)
                    #expect(try Data(contentsOf: subDir.appendingPathComponent("nested.dat")) == beta)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("top.dat")) != alpha)

                    let r2 = try await runCheckout(arguments: [".."], client: subClient, git: subGit)
                    #expect(r2.status == 0)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("top.dat")) == alpha)
                    #expect(try await repo.git.status().isClean)
                }
            }
        }

        @Test("pull downloads, deduplicates shared OIDs, checks out, and refreshes index")
        func pullDownloadsAndDeduplicates() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                server.store(beta, oid: oid(beta))
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [
                        ("a1.dat", alpha), ("sub/a2.dat", alpha), ("b.dat", beta)
                    ])

                    let result = try await runPull(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stdout.isEmpty)
                    #expect(result.stderr.isEmpty)
                    let gets = server.requests().filter { $0.method == "GET" }.map(\.path)
                    #expect(Set(gets) == Set(["/objects/\(oid(alpha))", "/objects/\(oid(beta))"]))
                    #expect(gets.count == 2)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("a1.dat")) == alpha)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("sub/a2.dat")) == alpha)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("b.dat")) == beta)
                    #expect(try await repo.git.status().isClean)
                }
            }
        }

        @Test("pull uses reference objects before downloading, with copy fallback for an existing object",
               arguments: [false, true])
        func pullUsesReferenceWithoutRequests(invalidLocalObject: Bool) async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha), ("sub/a.dat", alpha)])
                    let reference = repo.directory.deletingLastPathComponent().appendingPathComponent("reference.git")
                    try await GitClient(workingDirectory: reference).initRepository(bare: true)
                    let referenceStore = LocalStore(gitStorageDirectory: reference)
                    let source = try await referenceStore.objectPath(oid(alpha))
                    try alpha.write(to: source)
                    let alternates = repo.directory.appendingPathComponent(".git/objects/info/alternates")
                    try Data("\(reference.appendingPathComponent("objects").path.goQuoted)\n".utf8)
                        .write(to: alternates)
                    let destination = try await repo.store.objectPath(oid(alpha))
                    if invalidLocalObject { try Data("truncated".utf8).write(to: destination) }

                    let result = try await runPull(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stderr.isEmpty && result.stdout.isEmpty)
                    #expect(server.requests().isEmpty)
                    #expect(try Data(contentsOf: destination) == alpha)
                    #expect(try Data(contentsOf: source) == alpha)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("a.dat")) == alpha)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("sub/a.dat")) == alpha)
                    #expect(try await repo.git.status().isClean)
                }
            }
        }

        @Test("reference imports hard-link missing objects and copy over wrong-size local objects",
               arguments: [false, true])
        func referenceImportLinksOrCopies(invalidLocalObject: Bool) async throws {
            try await LFSTestServer.withServer { server in
                try await LFSServerRepository.run(server) { repo in
                    let reference = repo.directory.appendingPathComponent("reference.git")
                    let referenceStore = LocalStore(gitStorageDirectory: reference)
                    let source = try await referenceStore.objectPath(oid(alpha))
                    try alpha.write(to: source)
                    let destination = try await repo.store.objectPath(oid(alpha))
                    if invalidLocalObject { try Data("truncated".utf8).write(to: destination) }

                    try await repo.store.linkOrCopyFromReference(
                        oid(alpha), size: Int64(alpha.count), directories: [referenceStore.objectsDirectory.path])
                    #expect(try Data(contentsOf: destination) == alpha)
                    #expect(try Data(contentsOf: source) == alpha)
                    #if !os(Windows)
                    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
                    let targetAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    let sourceInode = sourceAttributes[.systemFileNumber] as? NSNumber
                    let targetInode = targetAttributes[.systemFileNumber] as? NSNumber
                    #expect((sourceInode == targetInode) == !invalidLocalObject)
                    #endif
                }
            }
        }

        @Test("pull downloads when a reference object has the wrong size")
        func pullRejectsWrongSizeReference() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                try await LFSServerRepository.run(server, config: LFSFilterFixture.commands) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha)])
                    let reference = repo.directory.deletingLastPathComponent().appendingPathComponent("reference.git")
                    try await GitClient(workingDirectory: reference).initRepository(bare: true)
                    let referenceStore = LocalStore(gitStorageDirectory: reference)
                    let source = try await referenceStore.objectPath(oid(alpha))
                    try Data("truncated".utf8).write(to: source)
                    try Data("\(reference.appendingPathComponent("objects").path)\n".utf8)
                        .write(to: repo.directory.appendingPathComponent(".git/objects/info/alternates"))

                    let result = try await runPull(client: repo.client, git: repo.git)
                    #expect(result.status == 0 && result.stderr.isEmpty)
                    #expect(server.requests().filter { $0.method == "GET" }.map(\.path) == ["/objects/\(oid(alpha))"])
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("a.dat")) == alpha)
                    #expect(try Data(contentsOf: source) == Data("truncated".utf8))
                    #expect(try await repo.git.status().isClean)
                }
            }
        }

        @Test("pull respects include/exclude, empty override, missing remote object, and invalid remote")
        func pullFiltersAndFailures() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                let config = LFSFilterFixture.commands + [("lfs.fetchinclude", "a.dat")]
                try await LFSServerRepository.run(server, config: config) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha), ("missing.dat", beta)])

                    let filtered = try await runPull(client: repo.client, git: repo.git)
                    #expect(filtered.status == 0)
                    #expect(try Data(contentsOf: repo.directory.appendingPathComponent("a.dat")) == alpha)
                    #expect(!repo.hasLocally(beta))

                    var clearInclude = PullOptions(); clearInclude.include = ""
                    let missing = try await runPull(clearInclude, client: repo.client, git: repo.git)
                    #expect(missing.status == 2)
                    let endpoint = server.endpoint.absoluteString
                    #expect(missing.stderr.contains("Failed to fetch some objects from '\(endpoint)'"))

                    let badRemote = try await runPull(arguments: ["nope"], client: repo.client, git: repo.git)
                    #expect(badRemote.status == 2)
                    #expect(badRemote.stderr.hasPrefix("Invalid remote name \"nope\":"))
                }
            }
        }

        @Test("checkout and pull without filter.lfs.clean and in bare or unborn repos")
        func notInstalledBareAndUnborn() async throws {
            try await LFSTestServer.withServer { server in
                server.store(alpha, oid: oid(alpha))
                try await LFSServerRepository.run(server) { repo in
                    // Unborn HEAD
                    let unbornCheckout = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(unbornCheckout.status == 2 && unbornCheckout.stderr == "Could not checkout\n")
                    let unbornPull = try await runPull(client: repo.client, git: repo.git)
                    #expect(unbornPull.status == 2 && unbornPull.stderr == "Could not pull\n")

                    try await commitTracked(repo, files: [("a.dat", alpha)])

                    // Not installed (no filter.lfs.clean)
                    let noCleanCheckout = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(noCleanCheckout.status == 0)
                    #expect(noCleanCheckout.stdout == "Cannot checkout LFS objects, Git LFS is not installed.\n")

                    let noCleanPull = try await runPull(client: repo.client, git: repo.git)
                    #expect(noCleanPull.status == 0)
                    let expectedSkip = "Skipping object checkout, Git LFS is not installed for this repository.\n"
                        + "Consider installing it with 'git lfs install'.\n"
                    #expect(noCleanPull.stdout == expectedSkip)
                    #expect(repo.hasLocally(alpha))
                    let pointer = Pointer(oid: oid(alpha), size: Int64(alpha.count)).encoded
                    #expect(try String(contentsOf: repo.directory.appendingPathComponent("a.dat"), encoding: .utf8)
                        == pointer)
                }
            }
        }

        @Test("checkout emits forced progress updates and done line")
        func checkoutForceProgress() async throws {
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await LFSTestServer.withServer { server in
                let config = LFSFilterFixture.commands + [("lfs.forceprogress", "true")]
                try await LFSServerRepository.run(server, config: config) { repo in
                    try await commitTracked(repo, files: [("a.dat", alpha)])
                    try await repo.storeLocally(alpha)
                    let result = try await runCheckout(client: repo.client, git: repo.git)
                    #expect(result.status == 0)
                    #expect(result.stdout.contains("Checking out LFS objects:   0% (0/1), 0 B | 0 B/s"))
                    #expect(result.stdout.hasSuffix("Checking out LFS objects: 100% (1/1), 18 B | 0 B/s, done.\n"))
                }
            }
        }
    }
}
