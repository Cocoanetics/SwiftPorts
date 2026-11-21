import Foundation
import HTTPTypes
import ShellKit

extension LFSTransferQueue {
    func upload(
        _ object: LFSBatchObject, action: LFSBatchAction, success: @escaping @Sendable () -> Void
    ) async throws {
        var request = try request(.put, action: action)
        if request.headerFields[.transferEncoding] != "chunked" {
            request.headerFields[.contentLength] = String(object.size)
        } else { request.headerFields[.contentLength] = nil }
        let file = URL(fileURLWithPath: object.path)
        try await Shell.authorize(file)
        let needsType = request.headerFields[.contentType]?.isEmpty != false
        let detect = needsType && client.finder.urlConfig.bool(
            prefix: "lfs", url: request.url?.absoluteString ?? action.href, key: "contenttype", fallback: true)
        let contentType = try Self.uploadContentType(file, object: object, detect: detect)
        if needsType { request.headerFields[.contentType] = contentType }
        let progress = report(object)
        let sent = LFSSentBytes()
        // `BodyWithCallback.ResetProgress`: a failed attempt, other than a 422,
        // takes back the bytes it reported, so a retry doesn't count them twice.
        func resetProgress() {
            let total = sent.total
            if total > 0 { progress(total, -total) }
        }
        let result: LFSTransferHTTPResult
        do {
            result = try await client.transfer(
                request, body: .file(file), operation: direction.rawValue, remote: remote,
                authenticated: object.authenticated,
                accessURL: request.url?.absoluteString.components(separatedBy: object.oid).first,
                stream: LFSTransferStream(progress: { total, delta in
                    sent.record(delta: delta)
                    progress(total, delta)
                }, success: success))
        } catch {
            try Task.checkCancellation()
            resetProgress()
            throw LFSTransferError(message: String(describing: error))
        }
        if result.status == 422 {
            var error = LFSTransferError(result, url: request.url, now: environment.now())
            error.retry = false
            error.unsupportedContentType = true
            throw error
        }
        guard result.accepted else {
            resetProgress()
            throw LFSTransferError(result, url: request.url, now: environment.now())
        }
        if sent.total < object.size { progress(object.size, object.size - sent.total) }
        try await verify(object)
    }

    /// Preflight uses the same synchronous Windows reader as the body.
    /// Queued uploads also read a 512-byte sniff before opening the transport;
    /// the plain transfer probes do not exercise that Foundation file-I/O path.
    static func uploadContentType(_ file: URL, object: LFSBatchObject, detect: Bool) throws -> String {
        #if os(Windows)
        let handle = try LFSCurlFile(url: file)
        guard handle.length == object.size else {
            throw LFSTransferError(message: "corrupt object: \(object.name) (\(object.oid))", retry: false)
        }
        guard detect else { return "application/octet-stream" }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = try handle.read(&bytes, count: 512)
        return HTTPContentType.detect(Data(bytes.prefix(count)))
        #else
        let handle = try FileHandle(forReadingFrom: file)
        do {
            let size = try handle.seekToEnd()
            guard size == UInt64(object.size) else {
                throw LFSTransferError(message: "corrupt object: \(object.name) (\(object.oid))", retry: false)
            }
            try handle.seek(toOffset: 0)
            let type = detect ? HTTPContentType.detect(try handle.read(upToCount: 512) ?? Data())
                : "application/octet-stream"
            try handle.close()
            return type
        } catch {
            try? handle.close()
            throw error
        }
        #endif
    }
}
