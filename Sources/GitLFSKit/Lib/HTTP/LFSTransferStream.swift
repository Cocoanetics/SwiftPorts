import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LFSTransferStream: Sendable {
    var destination: URL?
    var offset: Int64 = 0
    var progress: (@Sendable (Int64, Int64) -> Void)?
    var success: (@Sendable () -> Void)?

    func accepts(_ response: HTTPURLResponse) -> Bool {
        guard destination != nil else { return (200..<300).contains(response.statusCode) }
        if response.statusCode == 200 { return true }
        guard response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"),
              let match = range.range(of: #"bytes [0-9]+-.*"#, options: .regularExpression) else { return false }
        let start = range[match].dropFirst(6).prefix(while: { $0 != "-" })
        return Int64(start) == offset
    }
}
