import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Filter-only HTTP replies; independent of the transfer queue test suite.
final class LFSStreamURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> LFSTransferReply
    static let state = TransferTestLock<(Handler, [URLRequest])?>(nil)

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = data
        }
        let reply = Self.state.withLock { value -> LFSTransferReply? in
            value?.1.append(request)
            return value?.0(request)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LFSStreamURLProtocol.self]
        return configuration
    }
}
