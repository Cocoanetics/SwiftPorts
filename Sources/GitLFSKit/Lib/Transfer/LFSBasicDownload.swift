import Foundation
import HTTPTypes
import ShellKit

extension LFSTransferQueue {
    func download(
        _ object: LFSBatchObject, action: LFSBatchAction, success: @escaping @Sendable () -> Void
    ) async throws {
        try await LocalStore.makeDirectory(store.incompleteDirectory)
        let part = store.incompleteDirectory.appendingPathComponent(object.oid + ".part")
        try await Shell.authorize(part)
        if !FileManager.default.fileExists(atPath: part.path) { try Data().write(to: part) }
        let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
        let existing = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var from: Int64 = existing > 0 && existing < object.size - 1 ? existing : 0
        if from == 0 { try truncate(part) }
        while true {
            var request = try request(.get, action: action)
            if from > 0 { request.headerFields[.range] = "bytes=\(from)-\(object.size - 1)" }
            let result: LFSTransferHTTPResult
            do {
                result = try await client.transfer(
                    request, operation: direction.rawValue, remote: remote, authenticated: object.authenticated,
                    accessURL: request.url?.absoluteString.components(separatedBy: object.oid).first,
                    stream: LFSTransferStream(destination: part, offset: from,
                                              progress: report(object), success: success))
            } catch {
                try Task.checkCancellation()
                throw LFSTransferError(message: String(describing: error))
            }
            if from > 0, !result.accepted {
                try truncate(part)
                from = 0
                continue
            }
            guard result.accepted else {
                throw LFSTransferError(result, url: request.url, now: environment.now())
            }
            _ = try await store.insert(temporaryFile: part, oid: object.oid)
            return
        }
    }

    private func truncate(_ file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }
}
