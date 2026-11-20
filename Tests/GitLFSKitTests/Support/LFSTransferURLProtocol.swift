import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LFSTransferURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> LFSTransferReply
    private static let state = TransferTestLock<(Handler, [URLRequest])?>(nil)
    private let loading = TransferTestLock<Task<Void, Never>?>(nil)

    static func install(_ handler: @escaping Handler) { state.withLock { $0 = (handler, []) } }
    static func reset() { state.withLock { $0 = nil } }
    static var requests: [URLRequest] { state.withLock { $0?.1 ?? [] } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = data
        }
        let handler = Self.state.withLock { value -> Handler? in
            value?.1.append(request)
            return value?.0
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = handler(request)
        let task = Task { @Sendable [self] in
                await reply.beforeResponse?()
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                await reply.beforeBody?()
                guard !Task.isCancelled else { return }
                if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
                await reply.afterBody?()
                guard !Task.isCancelled else { return }
                if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure) }
                else { client?.urlProtocolDidFinishLoading(self) }
        }
        loading.withLock { $0 = task }
    }

    override func stopLoading() { loading.withLock { $0?.cancel() } }

    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LFSTransferURLProtocol.self]
        return config
    }
}
