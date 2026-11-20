import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Completed object requests retain status and headers, including failures.
struct LFSTransferHTTPResult: Sendable {
    let response: HTTPURLResponse
    let body: Data
    let accepted: Bool

    var status: Int { response.statusCode }
}
