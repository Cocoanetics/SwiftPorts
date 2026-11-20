import Foundation
import HTTPTypes
import ShellKit

/// The HTTP basic transfer queue (`tq.TransferQueue`). Progress reports bytes;
/// callers own presentation. Duplicate OIDs retain their first name and path.
public final class LFSTransferQueue: Sendable {
    let client: LFSClient
    let store: LocalStore
    let direction: LFSTransferDirection
    let remote: String?
    let refName: String
    let progress: (@Sendable (LFSTransferDirection, String, Int64, Int64, Int64) -> Void)?
    let settings: LFSTransferSettings
    let environment: LFSTransferEnvironment
    /// `tq.DryRun`: batch, but report every object with an action as transferred.
    let dryRun: Bool
    /// `tq.WithProgress`.
    let meter: LFSProgressMeter?
    /// Fires once per OID the queue finishes without an error.
    let completion: (@Sendable (LFSTransferCompletion) -> Void)?

    public convenience init(
        client: LFSClient, store: LocalStore, direction: LFSTransferDirection,
        remote: String, refName: String,
        progress: (@Sendable (LFSTransferDirection, String, Int64, Int64, Int64) -> Void)? = nil
    ) {
        self.init(client: client, store: store, direction: direction, remote: remote,
                  refName: refName, progress: progress, environment: LFSTransferEnvironment())
    }

    init(
        client: LFSClient, store: LocalStore, direction: LFSTransferDirection,
        remote: String, refName: String,
        progress: (@Sendable (LFSTransferDirection, String, Int64, Int64, Int64) -> Void)? = nil,
        environment: LFSTransferEnvironment,
        dryRun: Bool = false,
        meter: LFSProgressMeter? = nil,
        completion: (@Sendable (LFSTransferCompletion) -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.direction = direction
        self.remote = remote.isEmpty ? nil : remote
        self.refName = refName
        self.progress = progress
        self.environment = environment
        self.dryRun = dryRun
        self.meter = meter
        self.completion = completion
        settings = LFSTransferSettings(client.finder.configuration)
    }

    public func transfer(_ objects: [LFSBatchObject]) async throws {
        let failures = try await process(objects)
        if !failures.isEmpty { throw LFSClientError(failures.map(\.description).joined(separator: "\n")) }
    }

    /// The queue's run and `Wait`, returning `Errors()`. On upload, an OID in
    /// `missing` that the server asks for stops the queue
    /// (`newObjectMissingError`); a job whose file is absent or of the wrong
    /// size fails as missing or corrupt before any request is made.
    func process(_ objects: [LFSBatchObject], missing: Set<String> = []) async throws -> [LFSTransferFailure] {
        var seen: Set<String> = []
        var pending = objects.filter { seen.insert($0.oid).inserted }.map { LFSTransferPending(object: $0) }
        var failures: [LFSTransferFailure] = []
        var unsupported = false
        var authenticated = false
        while !pending.isEmpty {
            try Task.checkCancellation()
            let now = environment.now()
            var slice: [LFSTransferPending] = []
            var waiting: [LFSTransferPending] = []
            for item in pending {
                if item.ready <= now, slice.count < settings.batchSize { slice.append(item) }
                else { waiting.append(item) }
            }
            if slice.isEmpty {
                if let next = waiting.map(\.ready).min() {
                    try await environment.sleep(max(0, next.timeIntervalSince(now)))
                }
                continue
            }
            pending = waiting
            slice.sort { $0.object.size > $1.object.size }
            meter?.pause()
            let response: LFSBatchResponse
            do {
                response = try await client.batch(operation: direction.rawValue, objects: slice.map(\.object),
                                                  ref: LFSBatchRef(name: refName), remote: remote)
            } catch {
                try Task.checkCancellation()
                let message = String(describing: error)
                let shouldRetry = (error as? LFSClientError)?.retryInTransferQueue ?? true
                if !shouldRetry {
                    failures.append(.message(message))
                    continue
                }
                var retries: [LFSTransferPending] = []
                for item in slice {
                    if let item = scheduledRetry(item) { retries.append(item) }
                    else { failures.append(.message(message)) }
                }
                pending = retries + pending
                continue
            }
            guard let jobs = await jobs(for: response, slice: slice, missing: missing, failures: &failures)
            else { break }
            if dryRun {
                for item in jobs { finished(item.object) }
                continue
            }
            let workers = LFSTransferWorkers(jobs, authenticated: authenticated)
            let results = await run(workers)
            authenticated = workers.authenticated
            try Task.checkCancellation()
            var retries: [LFSTransferPending] = []
            for (item, error) in results {
                guard let error else {
                    finished(item.object)
                    continue
                }
                if error.unsupportedContentType { unsupported = true }
                if error.retry, let retry = scheduledRetry(item, delay: error.delay) {
                    retries.append(retry)
                } else { failures.append(.message(error.message)) }
            }
            pending = retries + pending
        }
        meter?.flush()
        if unsupported { environment.stderr(Self.contentTypeInfo) }
        return failures
    }

    /// The response's objects that have an action, in transfer order. An
    /// object without one is done; nil stops the queue on a missing upload.
    private func jobs(
        for response: LFSBatchResponse, slice: [LFSTransferPending], missing: Set<String>,
        failures: inout [LFSTransferFailure]
    ) async -> [LFSTransferPending]? {
        let originals = Dictionary(uniqueKeysWithValues: slice.map { ($0.object.oid, $0) })
        if direction == .upload {
            for object in response.objects where !object.actions.isEmpty && missing.contains(object.oid) {
                let name = originals[object.oid]?.object.name ?? object.name
                failures.append(.malformed(name: name, oid: object.oid, missing: true))
                return nil
            }
        }
        meter?.start()
        var returned: Set<String> = []
        var jobs: [LFSTransferPending] = []
        for var object in response.objects {
            guard var item = originals[object.oid] else {
                failures.append(.message("[\(object.oid)] The server returned an unknown OID."))
                meter?.skip(object.size)
                continue
            }
            guard returned.insert(object.oid).inserted else { continue }
            if let error = object.errorText {
                failures.append(.message(error))
                meter?.skip(object.size)
                continue
            }
            object.name = item.object.name
            object.path = item.object.path
            item.object = object
            if object.action(named: direction.rawValue) != nil {
                meter?.startTransfer(object.name)
                jobs.append(item)
            } else {
                meter?.skip(object.size)
                completion?(.skipped(object))
            }
        }
        for item in slice where !returned.contains(item.object.oid) {
            failures.append(.message("[\(item.object.oid)] The server did not return the requested OID."))
        }
        jobs.sort { $0.object.size > $1.object.size }
        if direction == .upload {
            var present: [LFSTransferPending] = []
            for item in jobs {
                if let failure = await Self.malformed(item.object) { failures.append(failure) }
                else { present.append(item) }
            }
            jobs = present
        }
        return jobs
    }

    private func finished(_ object: LFSBatchObject) {
        meter?.finishTransfer(object.name)
        completion?(.transferred(object))
    }

    /// `partitionTransfers`: an upload whose file is absent is missing, and
    /// one of the wrong size is corrupt.
    private static func malformed(_ object: LFSBatchObject) async -> LFSTransferFailure? {
        guard object.size >= 0 else { return nil }
        do {
            try await Shell.authorize(URL(fileURLWithPath: object.path))
        } catch {
            return .message(String(describing: error))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: object.path) else {
            return .malformed(name: object.name, oid: object.oid, missing: true)
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == object.size else {
            return .malformed(name: object.name, oid: object.oid, missing: false)
        }
        return nil
    }

    private func scheduledRetry(
        _ pending: LFSTransferPending, delay: TimeInterval? = nil
    ) -> LFSTransferPending? {
        var pending = pending
        guard pending.retries < settings.maxRetries else { return nil }
        pending.retries += 1
        let delay = delay ?? LFSRetryPolicy.delay(count: pending.retries, maximum: settings.maxRetryDelay)
        pending.ready = environment.now().addingTimeInterval(delay)
        return pending
    }

    private func run(_ workers: LFSTransferWorkers) async -> [(LFSTransferPending, LFSTransferError?)] {
        await withTaskGroup(of: [(LFSTransferPending, LFSTransferError?)].self) { group in
            for worker in 0..<settings.concurrency {
                group.addTask {
                    if worker > 0 { await workers.wait() }
                    var results: [(LFSTransferPending, LFSTransferError?)] = []
                    while !Task.isCancelled, let item = workers.next() {
                        do {
                            try await self.perform(item.object) { workers.success() }
                            results.append((item, nil))
                        } catch let error as LFSTransferError {
                            results.append((item, error))
                        } catch {
                            results.append((item, LFSTransferError(message: String(describing: error), retry: false)))
                        }
                    }
                    if worker == 0 { workers.finish() }
                    return results
                }
            }
            var results: [(LFSTransferPending, LFSTransferError?)] = []
            for await result in group { results += result }
            return results
        }
    }

    private func perform(_ object: LFSBatchObject, success: @escaping @Sendable () -> Void) async throws {
        guard let action = object.action(named: direction.rawValue) else { return }
        if action.isExpired(now: environment.now()), let at = action.expiration() {
            throw LFSTransferError(message: "[\(object.name)] LFS: action \(direction.rawValue.goQuoted) "
                + "expires at \(LFSTimestamp.rfc822(at))")
        }
        if object.size < 0 {
            throw LFSTransferError(message: "object \(object.oid.goQuoted) has invalid size (got: \(object.size))",
                                   retry: false)
        }
        switch direction {
        case .download: try await download(object, action: action, success: success)
        case .upload: try await upload(object, action: action, success: success)
        }
    }

    func request(_ method: HTTPRequest.Method, action: LFSBatchAction) throws -> HTTPRequest {
        var href = action.href
        if settings.rewrite {
            href = LFSEndpointDerivation.fromURL(
                href, upload: direction == .upload, gitProtocol: client.finder.gitProtocol,
                aliases: client.finder.aliases, base: store.gitStorageDirectory.path).url
        }
        try LFSClient.requireHTTP(LFSEndpoint(url: href))
        guard let url = URL(string: href) else { throw LFSClientError("invalid URL: \(href)") }
        var request = HTTPRequest(method: method, url: url)
        for (key, value) in action.header {
            if let name = HTTPField.Name(key) { request.headerFields[name] = value }
        }
        return request
    }

    func report(_ object: LFSBatchObject) -> @Sendable (Int64, Int64) -> Void {
        { read, delta in
            self.meter?.transferBytes(object.name, read: read, total: object.size, current: delta)
            self.progress?(self.direction, object.name, object.size, read, delta)
        }
    }

    static let contentTypeInfo = """
    info: Uploading failed due to unsupported Content-Type header(s).
    info: Consider disabling Content-Type detection with:
    info:
    info:   $ git config lfs.contenttype false

    """
}
