import Foundation

struct LFSTransferPending: Sendable {
    var object: LFSBatchObject
    var retries = 0
    var ready = Date.distantPast
}
