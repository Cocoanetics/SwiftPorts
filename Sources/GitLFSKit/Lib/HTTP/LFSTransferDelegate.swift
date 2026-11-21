import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serial URLSession callbacks write object chunks directly to disk. Only
/// non-object response bodies (API errors and upload responses) are buffered.
final class LFSTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let stream: LFSTransferStream
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<LFSTransferHTTPResult, Error>?
    private var response: HTTPURLResponse?
    private var file: FileHandle?
    private var body = Data()
    private var written: Int64 = 0
    private var failure: Error?
    private var accepted = false
    private var uploadFile: URL?

    init(stream: LFSTransferStream) { self.stream = stream }

    func execute(
        _ request: URLRequest, body: LFSRequestBody?, configuration: URLSessionConfiguration
    ) async throws -> LFSTransferHTTPResult {
        #if os(Windows)
        // swiftlint:disable:next todo
        // TODO: Remove this temporary workaround when the toolchain fixes
        // https://github.com/swiftlang/swift-corelibs-foundation/issues/5532
        if request.httpMethod == "PUT", let body, stream.destination == nil,
           LFSCurlUpload.usesDefaultProtocols(configuration) {
            return try await LFSCurlUpload(stream: stream).execute(request, body: body, configuration: configuration)
        }
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = request
                let task: URLSessionTask
                switch body {
                case .file(let url):
                    uploadFile = url
                    if request.value(forHTTPHeaderField: "Transfer-Encoding") == "chunked" {
                        // fromFile supplies a length even when the action asks
                        // for chunked encoding. A fresh disk stream preserves it.
                        request.httpBodyStream = InputStream(url: url)
                        task = session.uploadTask(withStreamedRequest: request)
                    } else {
                        task = session.uploadTask(with: request, fromFile: url)
                    }
                case .data(let data):
                    request.httpBody = data
                    task = session.dataTask(with: request)
                case .stream(let input):
                    request.httpBodyStream = input
                    task = session.dataTask(with: request)
                case nil: task = session.dataTask(with: request)
                }
                start(task)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = LFSClientError("Invalid HTTP status for \(dataTask.originalRequest?.httpMethod ?? "GET") "
                + "\(response.url?.absoluteString ?? ""): 0")
            completionHandler(.cancel)
            return
        }
        self.response = http
        accepted = stream.accepts(http)
        do {
            if accepted, let destination = stream.destination {
                let handle = try FileHandle(forWritingTo: destination)
                file = handle
                if http.statusCode == 206 {
                    try handle.seekToEnd()
                    written = stream.offset
                    if written > 0 { stream.progress?(written, written) }
                } else {
                    try handle.truncate(atOffset: 0)
                }
            }
            if accepted { stream.success?() }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if let file {
                try file.write(contentsOf: data)
                written += Int64(data.count)
                stream.progress?(written, Int64(data.count))
            } else if stream.destination == nil || (response?.statusCode ?? 0) >= 400 {
                body.append(data)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        stream.progress?(totalBytesSent, bytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(uploadFile.flatMap { InputStream(url: $0) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.close() } catch { failure = failure ?? error }
        file = nil
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: LFSTransferHTTPResult(
                response: response, body: body, accepted: accepted))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
