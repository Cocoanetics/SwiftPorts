import Foundation
import GitKit
import GitLFSKit
import Testing

extension PublicOperationTests {
    @Test("native clone applies effective configuration before its initial checkout")
    func cloneConfigurationBeforeCheckout() async throws {
        try await NativeFixture.run { fixture, server in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try Data("line\n".utf8).write(to: fixture.path("source/plain.txt"))
                    try repository.add(paths: ["plain.txt"])
                    _ = try repository.commitDetailed(message: "plain", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                }
            }
            fixture.shell.environment["GIT_CONFIG_COUNT"] = "2"
            fixture.shell.environment["GIT_CONFIG_KEY_1"] = "core.autocrlf"
            fixture.shell.environment["GIT_CONFIG_VALUE_1"] = "true"
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let clone = fixture.path("clone")
                try operation.authorize(fixture.path("source"))
                try operation.createRepository(at: clone, using: {
                    _ = try Repository.clone(from: fixture.path("source"), to: clone, progress: { _ in })
                }, { repository in
                    #expect(try repository.configGet("core.autocrlf") == "true")
                    let file = clone.appendingPathComponent("plain.txt")
                    let initialBytes = try Data(contentsOf: file)
                    #expect(initialBytes == Data("line\r\n".utf8),
                            "Native clone wrote bytes: \(Array(initialBytes))")
                    // Positive control: the prepared native handle does apply
                    // precisely the same option on a subsequent checkout.
                    try FileManager.default.removeItem(at: file)
                    try repository.checkoutPaths(["plain.txt"])
                    #expect(try Data(contentsOf: file) == Data("line\r\n".utf8))
                })
            }
        }
    }
}
