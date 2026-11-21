import Foundation
import ShellKit
import SwiftGit

/// `git lfs pull` (git-lfs 3.7.1 `commands/command_pull.go`).
///
/// Downloads missing LFS objects for the current checkout and checks out
/// eligible working-tree files from local storage, then refreshes the index.
///
/// Note: refreshing the Git index stat cache after rewriting working-tree
/// files requires the in-process LFS clean filter to be registered via
/// ``GitLFSKit/installFilter()``.
public struct PullOptions: Sendable {
    public var include: String?
    public var exclude: String?

    public init() {}

    public func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        try await run(arguments, client: client, git: git, terminal: terminal,
                      environment: LFSTransferEnvironment())
    }

    func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool,
        environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        do {
            let repo = try await LFSRepository.open(git, workTree: false)
            if let remote = arguments.first {
                try await client.finder.validateRemote(remote)
            }
            guard (try? await git.resolveOID("HEAD")) != nil else {
                throw LFSFailure("Could not pull")
            }
            let config = client.finder.configuration
            let filter = FilepathFilter(
                include: include.map(LFSConfiguration.cleanPaths) ?? config.fetchPaths("lfs.fetchinclude"),
                exclude: exclude.map(LFSConfiguration.cleanPaths) ?? config.fetchPaths("lfs.fetchexclude"))
            let remote: String
            if let explicit = arguments.first {
                remote = explicit
            } else {
                remote = await client.finder.downloadRemote()
            }
            return try await pull(
                filter: filter, remote: remote, client: client, git: git,
                repository: repo, terminal: terminal, environment: environment)
        } catch let failure as LFSFailure {
            return failure.result
        }
    }

    private func pull(
        filter: FilepathFilter, remote: String, client: LFSClient, git: GitClient,
        repository: LFSRepository, terminal: Bool, environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        let store = try await LocalStore.open(git)
        var single = try await LFSSingleCheckout.make(
            git: git, store: store, repository: repository, configuration: client.finder.configuration)
        let meter = await LFSProgressMeter.make(
            direction: .download, display: true, terminal: terminal,
            configuration: client.finder.configuration, environment: environment)
        let scanner = GitScanner(client: git, filter: filter)
        let pointers: [WrappedPointer]
        do {
            pointers = try await scanner.scanLFSFiles()
        } catch {
            await single.close()
            throw LFSFailure(String(describing: error))
        }

        var byOID: [String: [WrappedPointer]] = [:]
        var objects: [LFSBatchObject] = []
        for pointer in pointers {
            let oid = pointer.pointer.oid
            let size = pointer.pointer.size
            if byOID[oid] != nil {
                byOID[oid]?.append(pointer)
                continue
            }
            try? await store.linkOrCopyFromReference(oid, size: size, directories: single.referenceDirectories)
            if try await store.objectExists(oid, size: size) {
                await single.run(pointer)
                continue
            }
            meter.add(size)
            byOID[oid] = [pointer]
            let objectPath = try await store.objectPath(oid).path
            objects.append(LFSBatchObject(oid: oid, size: size, name: pointer.name, path: objectPath))
        }

        let completed = CompletedOIDs()
        let queue = LFSTransferQueue(
            client: client, store: store, direction: .download, remote: remote,
            refName: client.pushRemoteRef(await LFSClient.currentRef(git), remote: client.finder.uploadRemote()),
            environment: environment, dryRun: false, meter: meter,
            completion: { completion in
                switch completion {
                case .transferred(let object), .skipped(let object):
                    completed.append(object.oid)
                }
            })
        let failures = try await queue.process(objects)

        for oid in completed.all() {
            for pointer in byOID.removeValue(forKey: oid) ?? [] {
                await single.run(pointer)
            }
        }
        await single.close()

        var result = LFSCommandResult(stderr: single.stderr)
        for failure in failures {
            result.stderr += failure.description + "\n"
        }
        if !failures.isEmpty {
            let url = client.finder.endpoint(operation: "download", remote: remote).url
            result.fail("Failed to fetch some objects from '\(url)'")
            return result
        }
        if single.skip {
            result.stdout += "Skipping object checkout, Git LFS is not installed for this repository.\n"
                + "Consider installing it with 'git lfs install'.\n"
        }
        return result
    }
}

private final class CompletedOIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var oids: [String] = []

    func append(_ oid: String) {
        lock.withLock { oids.append(oid) }
    }

    func all() -> [String] {
        lock.withLock { oids }
    }
}
