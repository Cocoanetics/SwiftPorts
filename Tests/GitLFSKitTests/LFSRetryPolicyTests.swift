import Foundation
import Testing
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LFSRetryPolicyTests {
    @Test("exponential backoff caps even for overflowing shifts")
    func backoff() {
        #expect((1...8).map { LFSRetryPolicy.delay(count: $0, maximum: 10) }
            == [0.25, 0.5, 1, 2, 4, 8, 10, 10])
        #expect(LFSRetryPolicy.delay(count: Int.max, maximum: 10) == 10)
    }

    @Test("Retry-After accepts seconds and RFC1123 dates only on 429")
    func retryAfter() throws {
        let now = Date(timeIntervalSince1970: 0)
        func delay(_ status: Int, _ header: String) throws -> TimeInterval? {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://example.com/")!,
                statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": header]))
            return LFSRetryPolicy.retryAfter(
                LFSTransferHTTPResult(response: response, body: Data(), accepted: false), now: now)
        }
        #expect(try delay(429, "3600") == 3600)
        #expect(try delay(503, "3600") == nil)
        #expect(try delay(429, "Thu, 01 Jan 1970 00:00:07 GMT") == 7)
        #expect(try delay(429, "Wed, 31 Dec 1969 23:59:59 GMT") == 0)
        #expect(try delay(429, "no date") == nil)
    }
}
