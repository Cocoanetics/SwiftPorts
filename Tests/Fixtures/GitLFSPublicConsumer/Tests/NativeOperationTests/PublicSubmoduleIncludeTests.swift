import Foundation
import GitKit
import GitLFSKit
import ShellKit
import Testing

extension PublicOperationTests {
    @Test("submodule status include denials survive successful native returns",
           arguments: [false, true])
    func submoduleIncludeDenial(statusInsideRepository: Bool) async throws {
        try await NativeFixture.run { fixture, server in
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            let submodule = fixture.path("source/sub")
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                _ = try fixture.seed(operation, name: "sub-src")
                try operation.createRepository(at: submodule, using: { preparation in
                    try Repository.clone(from: fixture.path("sub-src"), to: submodule,
                                         progress: { _ in }, preparation: preparation)
                }, { _ in })
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try "[submodule \"sub\"]\n path = sub\n url = \(fixture.path("sub-src").path)\n"
                        .write(to: fixture.path("source/.gitmodules"), atomically: true, encoding: .utf8)
                    try repository.add(paths: [".gitmodules", "sub"])
                    _ = try repository.commitDetailed(message: "submodule", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                }
            }
            let included = fixture.path("denied.config")
            try "[consumer]\n secret = denied\n".write(to: included, atomically: true, encoding: .utf8)
            let config = submodule.appendingPathComponent(".git/config")
            let original = try String(contentsOf: config, encoding: .utf8)
            try (original + "\n[include]\n path = \(included.path)\n")
                .write(to: config, atomically: true, encoding: .utf8)
            fixture.shell.sandbox = fixture.sandbox { url in
                if url.standardizedFileURL == included.standardizedFileURL {
                    throw Sandbox.Denial(url: url, reason: "submodule include denied")
                }
            }
            var nativeReturned = false
            do {
                try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                    let repository = try operation.withRepository(at: fixture.path("source")) { repository in
                        if statusInsideRepository {
                            _ = try repository.status()
                            nativeReturned = true
                        }
                        return repository
                    }
                    if !statusInsideRepository {
                        _ = try repository.status()
                        nativeReturned = true
                    }
                }
                Issue.record("operation succeeded despite a denied submodule include")
            } catch let denial as Sandbox.Denial {
                #expect(denial.url.standardizedFileURL == included.standardizedFileURL)
                #expect(denial.reason == "submodule include denied")
            }
            #expect(nativeReturned)
        }
    }
}
