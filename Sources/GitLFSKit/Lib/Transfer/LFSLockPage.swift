/// `locking.lockVerifiableList`; absent slices have Go's nil-slice semantics.
struct LFSLockPage: Decodable {
    var ours: [LFSVerifiedLock]?
    var theirs: [LFSVerifiedLock]?
    var nextCursor: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case ours, theirs, message
        case nextCursor = "next_cursor"
    }
}
