import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LFSTransferURLProtocol: URLProtocol {
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
            // FoundationNetworking keeps the stream authoritative while it is
            // attached, so clear it before exposing the drained test body.
            request.httpBodyStream = nil
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
        // FoundationNetworking makes URLProtocol's Sendable conformance unavailable.
        // Keep the reference behind the test suite's unchecked, locked container.
        let protocolReference = TransferTestLock(self)
        let task = Task { @Sendable [protocolReference] in
            await reply.beforeResponse?()
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            protocolReference.withLock {
                $0.client?.urlProtocol($0, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            await reply.beforeBody?()
            guard !Task.isCancelled else { return }
            if !reply.body.isEmpty {
                protocolReference.withLock { $0.client?.urlProtocol($0, didLoad: reply.body) }
            }
            await reply.afterBody?()
            guard !Task.isCancelled else { return }
            protocolReference.withLock {
                if let failure = reply.failure { $0.client?.urlProtocol($0, didFailWithError: failure) }
                else { $0.client?.urlProtocolDidFinishLoading($0) }
            }
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
