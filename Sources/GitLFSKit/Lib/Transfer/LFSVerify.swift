import Foundation
import HTTPTypes

extension LFSTransferQueue {
    func verify(_ object: LFSBatchObject) async throws {
        guard let action = object.action(named: "verify") else { return }
        // `verifyUpload` does not apply the adapter's href rewrite.
        guard let url = URL(string: action.href) else { throw LFSClientError("invalid URL: \(action.href)") }
        try LFSClient.requireHTTP(LFSEndpoint(url: action.href))
        var json = JSONText()
        json.beginObject()
        json.key("oid")
        json.string(object.oid)
        json.key("size")
        json.number(object.size)
        json.endObject()
        let body = json.data
        var request = HTTPRequest(method: .post, url: url)
        request.headerFields[.contentType] = LFSMediaType.json
        request.headerFields[.accept] = LFSMediaType.json
        request.headerFields[.contentLength] = String(body.count)
        for (key, value) in action.header {
            if let name = HTTPField.Name(key) { request.headerFields[name] = value }
        }
        for attempt in 1...settings.maxVerifies {
            do {
                if object.authenticated {
                    let result = try await client.transfer(
                        request, body: .data(body), operation: "upload", remote: remote, authenticated: true)
                    if result.status >= 400 {
                        throw LFSClientError(LFSClient.httpMessage(status: result.status, body: result.body, url: url))
                    }
                } else {
                    try await client.send(request, body: .data(body), operation: "upload", remote: remote)
                }
                return
            } catch {
                try Task.checkCancellation()
                if attempt == settings.maxVerifies { throw error }
            }
        }
    }
}
