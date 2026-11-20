import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LFSTransferReply: Sendable {
    var status = 200
    var headers = ["Content-Type": "application/json"]
    var body = Data()
    var failure: URLError?
    var beforeResponse: (@Sendable () async -> Void)?
    var beforeBody: (@Sendable () async -> Void)?
    var afterBody: (@Sendable () async -> Void)?

    static func batch(
        _ request: URLRequest, operation: String = "download", headers: [String: String] = [:],
        verify: Bool = false, authenticated: Bool = false
    ) -> LFSTransferReply {
        let payload = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        let objects = (payload?["objects"] as? [[String: Any]] ?? []).map { original in
            var object = original
            let oid = original["oid"] as? String ?? ""
            var actions: [String: Any] = [operation: ["href": "https://example.com/objects/" + oid, "header": headers]]
            if verify { actions["verify"] = ["href": "https://example.com/verify/" + oid] }
            object["actions"] = actions
            object["authenticated"] = authenticated
            return object
        }
        return LFSTransferReply(body: (try? JSONSerialization.data(withJSONObject: ["objects": objects])) ?? Data())
    }
}
