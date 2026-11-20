import Foundation

/// Retry metadata stays internal; the user sees the underlying error alone.
struct LFSTransferError: Error, Sendable {
    let message: String
    var retry: Bool = true
    var delay: TimeInterval?
    var unsupportedContentType: Bool = false

    init(_ result: LFSTransferHTTPResult, url: URL?, now: Date) {
        message = LFSClient.httpMessage(status: result.status, body: result.body, url: url)
        delay = LFSRetryPolicy.retryAfter(result, now: now)
    }

    init(message: String, retry: Bool = true, unsupportedContentType: Bool = false) {
        self.message = message
        self.retry = retry
        self.unsupportedContentType = unsupportedContentType
    }
}
