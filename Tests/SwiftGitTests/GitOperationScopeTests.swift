import Foundation
import GitKit
import ShellKit
import Testing
@testable import SwiftGit

@Suite("Repository operation scope", .serialized)
struct GitOperationScopeTests {
    @Test("nested scope entry is rejected without deadlocking on the outer turn")
    func rejectsNestedEntry() async throws {
        let shell = Shell()
        let nestedError = try await GitRepositoryOperation.run(credentials: nil, shell: shell) { _ in
            let semaphore = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            Task {
                do {
                    _ = try await GitRepositoryOperation.run(credentials: nil, shell: shell) { _ in
                        Issue.record("nested operation entered its body")
                    }
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
            semaphore.wait()
            return box.error
        }
        #expect(nestedError as? GitFilterOperationContext.Failure == .unsupportedOperation)
    }

    @Test("GitClient clone and worktreeAdd apply effective config before initial checkout")
    func clientCloneAndWorktreeApplyConfigBeforeCheckout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGitOp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let baseShell = Shell(environment: Environment(variables: [
            "HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
            "GIT_CONFIG_NOSYSTEM": "1"
        ], workingDirectory: root.path))

        try await baseShell.withCurrent {
            let repo = try Repository.initialize(at: source, initialBranch: "main")
            try repo.configSet("user.name", "Test")
            try repo.configSet("user.email", "t@example.invalid")
            try repo.configSet("core.autocrlf", "false")
            try Data("line\n".utf8).write(to: source.appendingPathComponent("plain.txt"))
            try repo.add(paths: ["plain.txt"])
            _ = try repo.commitDetailed(
                message: "plain", author: Signature(name: "Test", email: "t@example.invalid"),
                allowEmpty: false, sign: .noSign)
        }

        let crlfShell = Shell(environment: Environment(variables: [
            "HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.autocrlf",
            "GIT_CONFIG_VALUE_0": "true"
        ], workingDirectory: root.path))

        try await crlfShell.withCurrent {
            let clone = root.appendingPathComponent("clone", isDirectory: true)
            let rootClient = GitClient(workingDirectory: root)
            try await rootClient.clone(url: source, directory: clone)
            #expect(try Data(contentsOf: clone.appendingPathComponent("plain.txt")) == Data("line\r\n".utf8))

            let linked = root.appendingPathComponent("linked", isDirectory: true)
            let sourceClient = GitClient(workingDirectory: source)
            try await sourceClient.worktreeAdd(path: linked, branch: "wt-crlf")
            #expect(try Data(contentsOf: linked.appendingPathComponent("plain.txt")) == Data("line\r\n".utf8))
        }
    }

    @Test("escaped RepositoryPreparation fails closed after the enclosing operation ends")
    func preparationRevokedAfterScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGitPrep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shell = Shell(environment: Environment(variables: [
            "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1"
        ], workingDirectory: root.path))
        let prepBox = PrepBox()
        try await GitRepositoryOperation.run(credentials: nil, shell: shell) { operation in
            prepBox.preparation = operation.preparation
        }
        let repo = try Repository.initialize(at: root.appendingPathComponent("target", isDirectory: true))
        let prep = try #require(prepBox.preparation)
        let cloneDest = root.appendingPathComponent("clone-after", isDirectory: true)
        #expect(throws: GitFilterOperationContext.Failure.expired) {
            _ = try Repository.clone(
                from: root.appendingPathComponent("target", isDirectory: true),
                to: cloneDest, progress: { _ in }, preparation: prep)
        }
        _ = repo
        #expect(!FileManager.default.fileExists(atPath: cloneDest.path))
    }

    private final class ErrorBox: @unchecked Sendable {
        var error: (any Error)?
    }

    private final class PrepBox: @unchecked Sendable {
        var preparation: RepositoryPreparation?
    }
}
