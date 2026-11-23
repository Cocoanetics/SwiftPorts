import Foundation
import GitKit
import GitLFSKit
import ShellKit
import Testing

extension PublicOperationTests {
    @Test("native clone and worktree bootstrap apply effective configuration before initial checkout")
    func creationConfigurationBeforeCheckout() async throws {
        try await NativeFixture.run { fixture, server in
            let first = try await GitLFSKit.withOperation(shell: fixture.shell) { operation -> String in
                _ = try fixture.seed(operation)
                return try operation.withRepository(at: fixture.path("source")) { repository in
                    try repository.configSet("core.autocrlf", "false")
                    try Data("line\n".utf8).write(to: fixture.path("source/plain.txt"))
                    try repository.add(paths: ["plain.txt"])
                    return try repository.commitDetailed(message: "plain", author: NativeFixture.signature,
                                                         allowEmpty: false, sign: .noSign).sha
                }
            }
            fixture.shell.environment["GIT_CONFIG_COUNT"] = "2"
            fixture.shell.environment["GIT_CONFIG_KEY_1"] = "core.autocrlf"
            fixture.shell.environment["GIT_CONFIG_VALUE_1"] = "true"
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let clone = fixture.path("clone")
                try operation.authorize(fixture.path("source"))
                try operation.createRepository(at: clone, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("source"), to: clone, progress: { _ in }, preparation: preparation)
                }, { repository in
                    #expect(try repository.configGet("core.autocrlf") == "true")
                    let initialBytes = try Data(contentsOf: clone.appendingPathComponent("plain.txt"))
                    #expect(initialBytes == Data("line\r\n".utf8),
                            "Native clone wrote bytes: \(Array(initialBytes))")
                    #expect(try Data(contentsOf: clone.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                })
                let linked = fixture.path("linked-crlf")
                try operation.authorize(linked)
                try operation.withRepository(at: fixture.path("source")) { repository in
                    let worktree = try repository.worktreeAdd(
                        path: linked, branch: "crlf-wt", startPoint: first, preparation: operation.preparation)
                    #expect(try worktree.configGet("core.autocrlf") == "true")
                    let initialBytes = try Data(contentsOf: linked.appendingPathComponent("plain.txt"))
                    #expect(initialBytes == Data("line\r\n".utf8),
                            "Native worktreeAdd wrote bytes: \(Array(initialBytes))")
                    #expect(try Data(contentsOf: linked.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                }
            }
        }
    }

    @Test("creation-time preparation authorizes or denies config includes without replaying creation",
           arguments: [false, true])
    func creationIncludeAuthorization(deny: Bool) async throws {
        try await NativeFixture.run { fixture, server in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
            }
            let extra = fixture.path("clone-extra.config")
            try "[consumer]\n\tfromCloneInclude = yes\n".write(to: extra, atomically: true, encoding: .utf8)
            let globalConfig = fixture.path("effective.config")
            let previous = try String(contentsOf: globalConfig, encoding: .utf8)
            try (previous + "\n[include]\n\tpath = \(extra.path)\n")
                .write(to: globalConfig, atomically: true, encoding: .utf8)
            fixture.shell.sandbox = fixture.sandbox { url in
                if deny, url.lastPathComponent == "clone-extra.config" {
                    throw Sandbox.Denial(url: url, reason: "clone include denied")
                }
            }
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            var cloneAttempts = 0
            let clone = fixture.path("clone-include")
            do {
                try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                    try operation.authorize(fixture.path("source"))
                    try operation.createRepository(at: clone, using: { preparation in
                        cloneAttempts += 1
                        return try Repository.clone(
                            from: fixture.path("source"), to: clone, progress: { _ in }, preparation: preparation)
                    }, { repository throws in
                        #expect(try repository.configGet("consumer.fromCloneInclude") == "yes")
                        #expect(try Data(contentsOf: clone.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                    })
                }
                #expect(!deny)
            } catch let error as Sandbox.Denial {
                #expect(deny)
                #expect(error.url.lastPathComponent == "clone-extra.config")
                #expect(!FileManager.default.fileExists(atPath: clone.path))
            }
            #expect(cloneAttempts == 1)
        }
    }
}

extension PublicOperationTests {
    /// Acceptance case for GitKit's creation rollback (GitKit #101 / #103).
    /// Until a released GitKit rolls back a failed `git_repository_init`
    /// open, the missing/empty clone and missing worktree cases fail on the
    /// artifacts libgit2 leaves behind.
    @Test("nested clone and worktree creation roll back a denied conditional include and retry cleanly",
          arguments: ["clone", "worktree"], ["missing", "empty", "occupied"])
    func nestedCreationIncludeDenial(kind: String, destinationState: String) async throws {
        try await NativeFixture.run { fixture, server in
            let first = try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try fixture.seed(operation)
            }
            let extra = fixture.path("nested-extra.config")
            try "[consumer]\n\tfromNestedInclude = yes\n".write(to: extra, atomically: true, encoding: .utf8)
            // Matches only the new repository's git directory, so the enclosing
            // body's own handle never reads it.
            let pattern = kind == "clone" ? "gitdir:**/nested-clone/" : "gitdir:**/.git/worktrees/"
            let globalConfig = fixture.path("effective.config")
            let previous = try String(contentsOf: globalConfig, encoding: .utf8)
            try (previous + "\n[includeIf \"\(pattern)\"]\n\tpath = \(extra.path)\n")
                .write(to: globalConfig, atomically: true, encoding: .utf8)
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)

            let destination = fixture.path("nested-\(kind)")
            let marker = destination.appendingPathComponent("host-file.txt")
            if destinationState != "missing" {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            if destinationState == "occupied" {
                try Data("host\n".utf8).write(to: marker)
            }
            // libgit2 refuses these before creating anything: a clone any non-empty
            // directory, a worktree any existing one.
            let refusedUpfront = destinationState == "occupied" || (kind == "worktree" && destinationState == "empty")
            let branch = "nested-\(kind)-branch"
            var attempts = 0
            func create() async throws {
                try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                    try operation.authorize(fixture.path("source"))
                    try operation.withRepository(at: fixture.path("source")) { source in
                        try operation.createRepository(at: destination, using: { preparation in
                            attempts += 1
                            if kind == "clone" {
                                return try Repository.clone(from: fixture.path("source"), to: destination,
                                                            progress: { _ in }, preparation: preparation)
                            }
                            return try source.worktreeAdd(path: destination, branch: branch,
                                                          startPoint: first, preparation: preparation)
                        }, { repository throws in
                            #expect(try repository.configGet("consumer.fromNestedInclude") == "yes")
                            #expect(try Data(contentsOf: destination.appendingPathComponent("a.lfs"))
                                    == NativeFixture.bytes)
                        })
                    }
                }
            }

            fixture.shell.sandbox = fixture.sandbox { url in
                if url.lastPathComponent == "nested-extra.config" {
                    throw Sandbox.Denial(url: url, reason: "nested include denied")
                }
            }
            do {
                try await create()
                Issue.record("nested creation succeeded despite the denied include")
            } catch let error as Sandbox.Denial {
                #expect(!refusedUpfront)
                #expect(error.url.lastPathComponent == "nested-extra.config")
            } catch {
                #expect(refusedUpfront, "unexpected error: \(error)")
            }
            #expect(attempts == 1)
            switch destinationState {
            case "missing":
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            case "empty":
                #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            default:
                #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["host-file.txt"])
                #expect(try Data(contentsOf: marker) == Data("host\n".utf8))
            }
            if kind == "worktree" {
                let sourceGit = fixture.path("source/.git")
                #expect(!FileManager.default.fileExists(
                    atPath: sourceGit.appendingPathComponent("worktrees/nested-worktree").path))
                #expect(!FileManager.default.fileExists(
                    atPath: sourceGit.appendingPathComponent("refs/heads/\(branch)").path))
            }
            guard !refusedUpfront else { return }

            fixture.shell.sandbox = fixture.sandbox { _ in }
            try await create()
            #expect(attempts == 2)
        }
    }
}

extension PublicOperationTests {
    @Test("nested creation keeps default and explicit configuration for its first checkout without persisting it",
          arguments: ["home", "explicit"])
    func nestedCreationConfiguration(globalSource: String) async throws {
        try await NativeFixture.run { fixture, server in
            let globalConfig = fixture.path("effective.config")
            let settings = "\n[core]\n\tautocrlf = true\n[consumer]\n\tglobalSource = \(globalSource)\n"
            let effective = try String(contentsOf: globalConfig, encoding: .utf8)
            if globalSource == "home" {
                // Ordinary defaults: the shell's HOME and XDG files, no GIT_CONFIG_GLOBAL.
                try (effective + settings).write(
                    to: fixture.path(".gitconfig"), atomically: true, encoding: .utf8)
                let xdg = fixture.path("xdg/git")
                try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
                try "[consumer]\n\tfromXDG = yes\n".write(
                    to: xdg.appendingPathComponent("config"), atomically: true, encoding: .utf8)
                fixture.shell.environment["GIT_CONFIG_GLOBAL"] = nil
            } else {
                try (effective + settings).write(to: globalConfig, atomically: true, encoding: .utf8)
            }
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try repository.configSet("core.autocrlf", "false")
                    try Data("line\n".utf8).write(to: fixture.path("source/plain.txt"))
                    try repository.add(paths: ["plain.txt"])
                    _ = try repository.commitDetailed(message: "plain", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                }
            }
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            let clone = fixture.path("nested-config")
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.authorize(fixture.path("source"))
                try operation.withRepository(at: fixture.path("source")) { source in
                    try operation.createRepository(at: clone, using: { preparation in
                        try Repository.clone(from: fixture.path("source"), to: clone,
                                             progress: { _ in }, preparation: preparation)
                    }, { repository throws in
                        #expect(try repository.configGet("core.autocrlf") == "true")
                        #expect(try repository.configGet("consumer.globalSource") == globalSource)
                        #expect(try repository.configGet("consumer.operation") == "scoped")
                        if globalSource == "home" {
                            #expect(try repository.configGet("consumer.fromXDG") == "yes")
                        }
                        #expect(try Data(contentsOf: clone.appendingPathComponent("plain.txt"))
                                == Data("line\r\n".utf8))
                        #expect(try Data(contentsOf: clone.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                        #expect(try repository.status().isClean)
                    })
                    // The enclosing scope is back once creation returns.
                    #expect(try source.configGet("consumer.globalSource") == globalSource)
                    let reopened = try Repository.open(at: clone)
                    #expect(try reopened.configGet("consumer.operation") == "scoped")
                    #expect(try reopened.configGet("core.autocrlf") == "true")
                    #expect(try reopened.configGet("consumer.globalSource") == globalSource)
                }
            }
            let local = try String(contentsOf: clone.appendingPathComponent(".git/config"), encoding: .utf8)
            for key in ["autocrlf", "globalSource", "operation", "fromXDG", "filter"] {
                #expect(!local.contains(key), "persisted \(key) in the clone's config:\n\(local)")
            }
        }
    }
}
