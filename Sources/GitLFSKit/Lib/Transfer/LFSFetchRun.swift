import Foundation
import ShellKit
import SwiftGit

/// The state one `git lfs fetch` carries across its refs: the watcher, the
/// output so far, and the per-call `fetch` / `pointersToFetch` steps.
struct LFSFetchRun {
    let client: LFSClient
    let git: GitClient
    let store: LocalStore
    let remote: String
    let dryRun: Bool
    let json: Bool
    let terminal: Bool
    let environment: LFSTransferEnvironment
    let watcher: LFSFetchWatcher
    var result = LFSCommandResult()

    // swiftlint:disable:next function_parameter_count
    init(
        client: LFSClient, git: GitClient, store: LocalStore, remote: String,
        dryRun: Bool, json: Bool, terminal: Bool, environment: LFSTransferEnvironment
    ) {
        self.client = client
        self.git = git
        self.store = store
        self.remote = remote
        self.dryRun = dryRun
        self.json = json
        self.terminal = terminal
        self.environment = environment
        watcher = LFSFetchWatcher(json: json, dryRun: dryRun)
    }

    private var logsProgress: Bool {
        terminal || LFSConfiguration.bool(Shell.env("GIT_LFS_FORCE_PROGRESS"), fallback: false)
            || client.finder.configuration.boolean("lfs.forceprogress")
    }

    /// A scan, or nil after git-lfs's `Panic` message. A history scan
    /// (`counting`) logs `N objects found` as a `tasklog.SimpleTask` on
    /// stdout: each count only on a terminal or with forced progress, the
    /// last with `, done.` regardless.
    mutating func scan(
        counting: Bool, _ body: () async throws -> [WrappedPointer]
    ) async -> [WrappedPointer]? {
        let pointers: [WrappedPointer]
        do {
            pointers = try await body()
        } catch {
            result.fail("Could not scan for Git LFS files")
            return nil
        }
        guard counting, !pointers.isEmpty else { return pointers }
        func found(_ count: Int) -> String { "\(count) object\(count == 1 ? "" : "s") found" }
        if logsProgress {
            for count in 1...pointers.count {
                let line = found(count)
                result.stdout += line + String(repeating: " ", count: max(0, 80 - line.utf8.count)) + "\r"
            }
        }
        result.stdout += found(pointers.count) + ", done.\n"
        return pointers
    }

    /// `fetch`: false when the queue reported errors, which go to stderr.
    mutating func fetch(_ pointers: [WrappedPointer]) async throws -> Bool {
        let meter = await LFSProgressMeter.make(
            direction: .download, display: !(json || dryRun), terminal: terminal,
            configuration: client.finder.configuration, environment: environment)
        var objects: [LFSBatchObject] = []
        var byOID: [String: [LFSBatchObject]] = [:]
        for pointer in pointers {
            let oid = pointer.pointer.oid, size = pointer.pointer.size
            if watcher.hasObserved(oid) || size == 0 { continue }
            if try await store.objectExists(oid, size: size) { continue }
            let object = LFSBatchObject(oid: oid, size: size, name: pointer.name,
                                        path: try await store.objectPath(oid).path)
            objects.append(object)
            byOID[oid, default: []].append(object)
            meter.add(size)
        }
        let watcher = watcher
        let queue = LFSTransferQueue(
            client: client, store: store, direction: .download, remote: remote,
            refName: client.pushRemoteRef(await LFSClient.currentRef(git), remote: client.finder.uploadRemote()),
            environment: environment, dryRun: dryRun, meter: meter,
            completion: { [byOID] completion in
                guard case .transferred(let object) = completion else { return }
                // One update for each pointer that shares the OID.
                for pointer in byOID[object.oid] ?? [] {
                    var transfer = object
                    transfer.name = pointer.name
                    transfer.path = pointer.path
                    transfer.size = pointer.size
                    transfer.authenticated = false
                    transfer.error = nil
                    watcher.register(transfer)
                }
            })
        let failures = try await queue.process(objects)
        result.stdout += meter.drain()
        result.stderr += watcher.drainProgress()
        for failure in failures { result.stderr += failure.description + "\n" }
        return failures.isEmpty
    }
}
