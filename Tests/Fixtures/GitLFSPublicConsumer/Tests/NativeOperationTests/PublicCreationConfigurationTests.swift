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
