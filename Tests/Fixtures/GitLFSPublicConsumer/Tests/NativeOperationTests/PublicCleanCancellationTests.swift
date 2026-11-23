import Foundation
import GitKit
import GitLFSKit
import Testing

extension PublicOperationTests {
    @Test("cancelled clean paths leave no temporary files when sandbox authorization resumes",
           arguments: ["add", "status", "diff"], [16, 2048])
    func cleanCancellation(command: String, size: Int) async throws {
        try await NativeFixture.run { fixture, _ in
            let originalPointer = try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                return try operation.withRepository(at: fixture.path("source")) { repository in
                    try Data(repeating: 0x62, count: size).write(to: fixture.path("source/a.lfs"))
                    try repository.add(paths: ["a.lfs"])
                    _ = try repository.commitDetailed(message: "content size", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                    return try repository.catFileBlob("HEAD:a.lfs")
                }
            }
            try Data(repeating: 0x61, count: size).write(to: fixture.path("source/a.lfs"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                ofItemAtPath: fixture.path("source/a.lfs").path)
            let temporaryDirectory = fixture.store().temporaryDirectory.standardizedFileURL
            let gate = CancellationAuthorizationGate()
            fixture.shell.sandbox = fixture.sandbox { url in
                if url.deletingLastPathComponent().standardizedFileURL == temporaryDirectory {
                    await gate.suspend()
                }
            }
            let task = Task {
                do {
                    try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                        try operation.withRepository(at: fixture.path("source")) { repository in
                            switch command {
                            case "add": try repository.add(paths: ["a.lfs"])
                            case "status": _ = try repository.status()
                            default: _ = try repository.diff(.workdirVsIndex)
                            }
                        }
                    }
                    await gate.finish()
                } catch {
                    await gate.finish()
                    throw error
                }
            }
            guard await gate.waitUntilEntered() else {
                try await task.value
                Issue.record("native clean did not reach temporary-file authorization")
                return
            }
            task.cancel()
            await gate.resume()
            do {
                try await task.value
                Issue.record("cancelled clean succeeded")
            } catch let error as GitFilterError {
                #expect(error.underlying is CancellationError)
            } catch is CancellationError {
                // The operation boundary can observe cancellation directly.
            }
            #expect(try FileManager.default.contentsOfDirectory(
                at: temporaryDirectory, includingPropertiesForKeys: nil).isEmpty)
            // The cancelled clean must not have staged its output.
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.withRepository(at: fixture.path("source")) { repository throws in
                    let entry = try #require(try repository.indexedEntries().first { $0.path == "a.lfs" })
                    #expect(try repository.catFileBlob(entry.oid) == originalPointer)
                }
            }
        }
    }
}

extension PublicOperationTests {
    @Test("cancelled optional clean neither stages full content nor lets a following commit move HEAD",
          arguments: [16, 2048])
    func optionalCleanCancellation(size: Int) async throws {
        try await NativeFixture.run { fixture, _ in
            let globalConfig = fixture.path("effective.config")
            let config = try String(contentsOf: globalConfig, encoding: .utf8)
            try config.replacingOccurrences(of: "required = true", with: "required = false")
                .write(to: globalConfig, atomically: true, encoding: .utf8)
            let (originalPointer, originalHead) = try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                return try operation.withRepository(at: fixture.path("source")) { repository in
                    #expect(try repository.configGet("filter.lfs.required") == "false")
                    return (try repository.catFileBlob("HEAD:a.lfs"), try repository.resolveOID("HEAD"))
                }
            }
            try Data(repeating: 0x61, count: size).write(to: fixture.path("source/a.lfs"))
            let temporaryDirectory = fixture.store().temporaryDirectory.standardizedFileURL
            let gate = CancellationAuthorizationGate()
            fixture.shell.sandbox = fixture.sandbox { url in
                if url.deletingLastPathComponent().standardizedFileURL == temporaryDirectory {
                    await gate.suspend()
                }
            }
            let task = Task {
                do {
                    try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                        try operation.withRepository(at: fixture.path("source")) { repository in
                            try repository.add(paths: ["a.lfs"])
                            _ = try repository.commitDetailed(message: "after cancellation",
                                                               author: NativeFixture.signature,
                                                               allowEmpty: false, sign: .noSign)
                        }
                    }
                    await gate.finish()
                } catch {
                    await gate.finish()
                    throw error
                }
            }
            guard await gate.waitUntilEntered() else {
                try await task.value
                Issue.record("optional clean did not reach temporary-file authorization")
                return
            }
            task.cancel()
            await gate.resume()
            do {
                try await task.value
                Issue.record("cancelled optional clean succeeded")
            } catch let error as GitFilterError {
                #expect(error.underlying is CancellationError)
            } catch is CancellationError {
                // The operation boundary can observe cancellation directly.
            }
            #expect(try FileManager.default.contentsOfDirectory(
                at: temporaryDirectory, includingPropertiesForKeys: nil).isEmpty)
            fixture.shell.sandbox = nil
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.withRepository(at: fixture.path("source")) { repository throws in
                    #expect(try repository.resolveOID("HEAD") == originalHead)
                    let entry = try #require(try repository.indexedEntries().first { $0.path == "a.lfs" })
                    #expect(try repository.catFileBlob(entry.oid) == originalPointer)
                }
            }
        }
    }
}
