/// Wire headers and bytes observed by the independent Python receiver.
struct LFSPlainUploadReceipt: Decodable {
    var headers: [String: String]
    var received: Int
    var sha256: String
}
