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
        let handle = try FileHandle(forReadingFrom: file)
        do {
            if request.headerFields[.contentType]?.isEmpty != false {
                let detect = client.finder.urlConfig.bool(
                    prefix: "lfs", url: request.url?.absoluteString ?? action.href, key: "contenttype", fallback: true)
                request.headerFields[.contentType] = detect
                    ? HTTPContentType.detect(try handle.read(upToCount: 512) ?? Data()) : "application/octet-stream"
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let result: LFSTransferHTTPResult
        do {
            result = try await client.transfer(
                request, body: .file(file), operation: direction.rawValue, remote: remote,
                authenticated: object.authenticated,
                accessURL: request.url?.absoluteString.components(separatedBy: object.oid).first,
                stream: LFSTransferStream(progress: report(object), success: success))
        } catch {
            try Task.checkCancellation()
            throw LFSTransferError(message: String(describing: error))
        }
        if result.status == 422 {
            throw LFSTransferError(message: "", retry: false, unsupportedContentType: true)
        }
        guard result.accepted else {
            throw LFSTransferError(result, url: request.url, now: environment.now())
        }
        try await verify(object)
    }
}
