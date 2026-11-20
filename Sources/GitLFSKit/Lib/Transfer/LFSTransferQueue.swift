import Foundation
import HTTPTypes

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
        environment: LFSTransferEnvironment
    ) {
        self.client = client
        self.store = store
        self.direction = direction
        self.remote = remote.isEmpty ? nil : remote
        self.refName = refName
        self.progress = progress
        self.environment = environment
        settings = LFSTransferSettings(client.finder.configuration)
    }

    public func transfer(_ objects: [LFSBatchObject]) async throws {
        var seen: Set<String> = []
        var pending = objects.filter { seen.insert($0.oid).inserted }.map { LFSTransferPending(object: $0) }
        var failures: [String] = []
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
            let response: LFSBatchResponse
            do {
                response = try await client.batch(operation: direction.rawValue, objects: slice.map(\.object),
                                                  ref: LFSBatchRef(name: refName), remote: remote)
            } catch {
                try Task.checkCancellation()
                failures.append(String(describing: error))
                continue
            }
            let originals = Dictionary(uniqueKeysWithValues: slice.map { ($0.object.oid, $0) })
            var jobs: [LFSTransferPending] = []
            for var object in response.objects {
                guard var item = originals[object.oid] else { continue }
                object.name = item.object.name
                object.path = item.object.path
                item.object = object
                if let error = object.errorText { failures.append(error) }
                else if object.action(named: direction.rawValue) != nil { jobs.append(item) }
            }
            jobs.sort { $0.object.size > $1.object.size }
            let workers = LFSTransferWorkers(jobs, authenticated: authenticated)
            let results = await run(workers)
            authenticated = workers.authenticated
            try Task.checkCancellation()
            var retries: [LFSTransferPending] = []
            for (var item, error) in results {
                guard let error else { continue }
                if error.unsupportedContentType { unsupported = true; continue }
                if error.retry, item.retries < settings.maxRetries {
                    item.retries += 1
                    let delay = error.delay ?? LFSRetryPolicy.delay(
                        count: item.retries, maximum: settings.maxRetryDelay)
                    item.ready = environment.now().addingTimeInterval(delay)
                    retries.append(item)
                } else { failures.append(error.message) }
            }
            pending = retries + pending
        }
        if unsupported { environment.stderr(Self.contentTypeInfo) }
        if !failures.isEmpty { throw LFSClientError(failures.joined(separator: "\n")) }
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
        { read, delta in self.progress?(self.direction, object.name, object.size, read, delta) }
    }

    static let contentTypeInfo = """
    info: Uploading failed due to unsupported Content-Type header(s).
    info: Consider disabling Content-Type detection with:
    info:
    info:   $ git config lfs.contenttype false

    """
}
