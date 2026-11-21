/// One error the transfer queue collected (`TransferQueue.Errors`).
/// `malformed` is `tq.MalformedObjectError`, which the uploader reports
/// in its own block.
enum LFSTransferFailure: Sendable, Equatable, CustomStringConvertible {
    case message(String)
    case malformed(name: String, oid: String, missing: Bool)

    var description: String {
        switch self {
        case .message(let message): message
        case .malformed(let name, let oid, let missing):
            "\(missing ? "missing" : "corrupt") object: \(name) (\(oid))"
        }
    }
}
