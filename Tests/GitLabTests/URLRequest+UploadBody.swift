import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLRequest {
    /// The request with its upload body restored for a `URLProtocol`.
    ///
    /// swift-corelibs-foundation (Linux, Windows) keeps the body of an
    /// `upload(for:from:)` task in the task's internal `knownBody`
    /// (`_Body.data(DispatchData)`) and hands the protocol a request with
    /// neither `httpBody` nor `httpBodyStream`. Darwin delivers a body
    /// stream, so this is a no-op there. Test-only: it reads Foundation
    /// internals through `Mirror` and returns the request unchanged if
    /// that layout ever moves.
    func withUploadBody(from task: URLSessionTask?) -> URLRequest {
        guard httpBody == nil, httpBodyStream == nil, let task else { return self }
        var mirror: Mirror? = Mirror(reflecting: task)
        while let current = mirror {
            if let known = current.children.first(where: { $0.label == "knownBody" })?.value {
                guard let body = Mirror(reflecting: known).children.first?.value,
                      let payload = Mirror(reflecting: body).children.first,
                      payload.label == "data"
                else { return self }
                var request = self
                if let data = payload.value as? DispatchData {
                    request.httpBody = Data(data)
                } else if let data = payload.value as? Data {
                    request.httpBody = data
                }
                return request
            }
            mirror = current.superclassMirror
        }
        return self
    }
}
