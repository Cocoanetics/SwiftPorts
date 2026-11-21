import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serial URLSession callbacks write object chunks directly to disk. Only
/// non-object response bodies (API errors and upload responses) are buffered.
final class LFSTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Temporary test-only opt-in for #243. Capture the sink before entering
    // URLSession callbacks, which do not inherit the caller's task locals.
    @TaskLocal static var uploadDiagnostic: (@Sendable (String) -> Void)?

    private let stream: LFSTransferStream
    private let diagnostic: (@Sendable (String) -> Void)?
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
    private var tracesUpload = false
    private var uploadTraceID = ""

    init(stream: LFSTransferStream) {
        self.stream = stream
        diagnostic = Self.uploadDiagnostic
    }

    func execute(
        _ request: URLRequest, body: LFSRequestBody?, configuration: URLSessionConfiguration
    ) async throws -> LFSTransferHTTPResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = request
                tracesUpload = diagnostic != nil && request.httpMethod == "PUT"
                    && (Int64(request.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) >= 1_000_000
                if tracesUpload {
                    uploadTraceID = String(request.url?.lastPathComponent.suffix(12) ?? "")
                    let kind: String
                    switch body {
                    case .file: kind = "file"
                    case .stream: kind = "stream"
                    case .data: kind = "data"
                    case nil: kind = "none"
                    }
                    let length = request.value(forHTTPHeaderField: "Content-Length") ?? "unset"
                    diagnostic?("[LFS #243 client \(uploadTraceID)] starting PUT body=\(kind) length=\(length)")
                }
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
        if tracesUpload { diagnostic?("[LFS #243 client \(uploadTraceID)] response status=\(http.statusCode)") }
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
        if tracesUpload {
            diagnostic?("[LFS #243 client \(uploadTraceID)] sent=\(totalBytesSent) delta=\(bytesSent)"
                + " expected=\(totalBytesExpectedToSend)")
        }
        stream.progress?(totalBytesSent, bytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        if tracesUpload {
            diagnostic?("[LFS #243 client \(uploadTraceID)] needNewBodyStream file=\(uploadFile != nil)")
        }
        completionHandler(uploadFile.flatMap { InputStream(url: $0) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if tracesUpload {
            let code = (error as NSError?)?.code ?? 0
            diagnostic?("[LFS #243 client \(uploadTraceID)] completed sent=\(task.countOfBytesSent) errorCode=\(code)")
        }
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
