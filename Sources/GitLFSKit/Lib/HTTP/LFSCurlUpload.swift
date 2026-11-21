#if os(Windows)
import CLFSCurl
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Windows-only production workaround for Foundation's socket-readiness stall:
/// https://github.com/swiftlang/swift-corelibs-foundation/issues/5532
/// Plain 1 MB file/Data PUTs stall with valid Content-Length and no Expect wait,
/// before any response; the server drains every reported byte until request end.
/// Fixing the stream probe's conflicting framing does not fix those uploads.
/// Use libcurl's polling loop rather than Foundation's Dispatch socket sources;
/// Each attempt has one worker and bounded reads; auth/retries stay in LFSClient.
final class LFSCurlUpload: @unchecked Sendable {
    // Swift's lazy static initialization is serialized across upload workers.
    private static let initialized = sp_lfs_curl_initialize()
    private let stream: LFSTransferStream
    private let diagnostic = LFSUploadDiagnostics.sink
    private let lock = NSLock()
    private var cancelled = false
    private var file: LFSCurlFile?
    private var input: InputStream?
    private var data: Data?
    private var offset = 0
    private var sent: Int64 = 0
    private var readCalls = 0
    private var failure: Error?
    private var response: HTTPURLResponse?
    private var responseURL: URL?
    private var responseBody = Data()
    private var status = 0
    private var headers: [String: String] = [:]
    private var readingHeaders = false
    private var redirecting = false
    private var lastActivity = ContinuousClock.now
    private var networkSent: Int64 = 0
    private var networkReceived: Int64 = 0
    private var idleTimeout: TimeInterval = 60
    private var cookieStorage: HTTPCookieStorage?

    init(stream: LFSTransferStream) { self.stream = stream }

    /// A caller-supplied URLProtocol must continue through URLSession, including
    /// embedders' custom transports and the SDK's existing HTTP mocks.
    static func usesDefaultProtocols(_ configuration: URLSessionConfiguration) -> Bool {
        let supplied = (configuration.protocolClasses ?? []).map(ObjectIdentifier.init)
        let defaults = (URLSessionConfiguration.ephemeral.protocolClasses ?? []).map(ObjectIdentifier.init)
        return supplied.isEmpty || supplied == defaults
    }

    func execute(
        _ request: URLRequest, body: LFSRequestBody, configuration: URLSessionConfiguration
    ) async throws -> LFSTransferHTTPResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        continuation.resume(returning: try perform(request, body: body, configuration: configuration))
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
    }

    private func perform(
        _ request: URLRequest, body: LFSRequestBody, configuration: URLSessionConfiguration
    ) throws -> LFSTransferHTTPResult {
        guard let url = request.url else { throw URLError(.badURL) }
        guard Self.initialized == 0 else {
            diagnostic?("curl initialization CURLcode=\(Self.initialized)")
            throw URLError(.cannotConnectToHost)
        }
        responseURL = url
        if request.httpShouldHandleCookies, configuration.httpShouldSetCookies {
            cookieStorage = configuration.httpCookieStorage
        }
        lastActivity = .now
        idleTimeout = configuration.timeoutIntervalForRequest
        defer { file = nil; input?.close() }
        var length: Int64
        let sourceKind: String
        switch body {
        case .file(let url):
            sourceKind = "file"
            let source = try LFSCurlFile(url: url)
            file = source
            length = source.length
        case .data(let bytes):
            sourceKind = "data"
            data = bytes
            length = Int64(bytes.count)
        case .stream(let source):
            sourceKind = "stream"
            input = source
            source.open()
            length = -1
        }
        var fields = requestHeaders(request, configuration: configuration, url: url)
        if fields["transfer-encoding"] == "chunked" { length = -1 }
        else if let supplied = fields["content-length"].flatMap(Int64.init) { length = supplied }
        // Foundation suppresses curl's implicit Expect header; action-supplied
        // Expect: 100-continue is preserved.
        if fields["expect"] == nil { fields["expect"] = "" }
        let headerLines = fields.map { "\($0.key): \($0.value)" }
        var detail = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let proxy = proxySettings(configuration, url: url)
        let proxyMode = proxy.address.map { $0.isEmpty ? "disabled" : "configured" } ?? "environment"
        diagnostic?("transport=curl source=\(sourceKind) scheme=\(url.scheme ?? "") host=\(url.host ?? "") "
            + "length=\(length) chunked=\(fields["transfer-encoding"] == "chunked") "
            + "expectContinue=\(fields["expect"] == "100-continue") proxy=\(proxyMode)")
        let result = sp_lfs_curl_upload(
            url.absoluteString, request.httpMethod ?? "PUT", headerLines.joined(separator: "\r\n"), length,
            milliseconds(configuration.timeoutIntervalForRequest),
            milliseconds(configuration.timeoutIntervalForResource),
            proxy.address, proxy.exceptions, cookieStorage == nil ? 0 : 1,
            context,
            { context, buffer, count in
                guard let context, let buffer else { return 0x10000000 }
                return Unmanaged<LFSCurlUpload>.fromOpaque(context).takeUnretainedValue().read(buffer, count: count)
            },
            { context, buffer, count in
                guard let context, let buffer else { return 0 }
                let upload = Unmanaged<LFSCurlUpload>.fromOpaque(context).takeUnretainedValue()
                upload.lastActivity = .now
                if !upload.redirecting { upload.responseBody.append(buffer, count: count) }
                return count
            },
            { context, buffer, count in
                guard let context, let buffer else { return 0 }
                let upload = Unmanaged<LFSCurlUpload>.fromOpaque(context).takeUnretainedValue()
                upload.receiveHeader(String(decoding: UnsafeBufferPointer(start: buffer, count: count), as: UTF8.self))
                return count
            },
            { context, offset, origin in
                guard let context else { return 1 }
                return Unmanaged<LFSCurlUpload>.fromOpaque(context).takeUnretainedValue().seek(offset, origin: origin)
            },
            { context, sent, received in
                guard let context else { return 1 }
                return Unmanaged<LFSCurlUpload>.fromOpaque(context).takeUnretainedValue().checkpoint(sent, received)
            }, &detail, 256)
        let bytes = detail.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let message = String(decoding: bytes, as: UTF8.self)
        let description = sp_lfs_curl_error_string(result).map {
            String(decodingCString: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), as: UTF8.self)
        } ?? "unknown"
        diagnostic?("CURLcode=\(result) curl_easy_strerror=\(description) detail=\(message) "
            + "readCalls=\(readCalls) bodyRead=\(sent) networkSent=\(networkSent) "
            + "networkReceived=\(networkReceived) status=\(status)")
        if let failure { throw failure }
        guard result == 0 else {
            let code: URLError.Code
            switch result {
            case 6: code = .cannotFindHost
            case 7: code = .cannotConnectToHost
            case 28: code = .timedOut
            case 35, 60: code = .secureConnectionFailed
            case 42: code = .cancelled
            default: code = .networkConnectionLost
            }
            // The raw CURLcode identifies this transport in a mapped failure.
            throw URLError(code, userInfo: [NSLocalizedDescriptionKey: message, "CURLcode": result])
        }
        guard let response else { throw URLError(.badServerResponse) }
        return LFSTransferHTTPResult(response: response, body: responseBody, accepted: stream.accepts(response))
    }

    private func requestHeaders(
        _ request: URLRequest, configuration: URLSessionConfiguration, url: URL
    ) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in configuration.httpAdditionalHeaders ?? [:] {
            if let key = key as? String, let value = value as? String { fields[key.lowercased()] = value }
        }
        for (key, value) in request.allHTTPHeaderFields ?? [:] { fields[key.lowercased()] = value }
        if request.httpShouldHandleCookies, configuration.httpShouldSetCookies,
           fields["cookie"] == nil, let cookies = configuration.httpCookieStorage?.cookies(for: url) {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                fields[key.lowercased()] = value
            }
        }
        return fields
    }

    private func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        readCalls += 1
        if lock.withLock({ cancelled }) { failure = URLError(.cancelled); return 0x10000000 }
        do {
            let count = min(count, 64 * 1024)
            let amount: Int
            if let file {
                amount = try file.read(buffer, count: count)
            } else if let input {
                amount = input.read(buffer, maxLength: count)
                if amount < 0 { throw input.streamError ?? URLError(.cannotOpenFile) }
            } else if let data {
                amount = min(count, data.count - offset)
                data.copyBytes(to: buffer, from: offset..<(offset + amount))
                offset += amount
            } else { amount = 0 }
            sent += Int64(amount)
            if amount > 0 { stream.progress?(sent, Int64(amount)) }
            return amount
        } catch {
            failure = error
            return 0x10000000 // CURL_READFUNC_ABORT
        }
    }

    private func seek(_ offset: Int64, origin: Int32) -> Int32 {
        guard origin == 0, offset >= 0 else { return 2 } // CURL_SEEKFUNC_CANTSEEK
        do {
            if let file { try file.seek(to: offset) }
            else if let data, offset <= Int64(data.count) { self.offset = Int(offset) }
            else { return 2 }
            if sent > 0 { stream.progress?(sent, -sent) }
            sent = 0
            return 0
        } catch { failure = error; return 1 }
    }

    private func checkpoint(_ sent: Int64, _ received: Int64) -> Int32 {
        if lock.withLock({ cancelled }) { failure = URLError(.cancelled); return 1 }
        if sent != networkSent || received != networkReceived {
            lastActivity = .now
            networkSent = sent
            networkReceived = received
        }
        if idleTimeout > 0, lastActivity.duration(to: .now) >= .seconds(idleTimeout) {
            failure = URLError(.timedOut)
            return 1
        }
        return 0
    }

    private func receiveHeader(_ line: String) {
        lastActivity = .now
        if line.hasPrefix("HTTP/") {
            status = Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
            headers.removeAll(keepingCapacity: true)
            responseBody.removeAll(keepingCapacity: true)
            readingHeaders = true
            redirecting = false
        } else if line == "\r\n", readingHeaders {
            readingHeaders = false
            guard status >= 200, let url = responseURL else { return }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            cookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
            if [301, 302, 303, 307, 308].contains(status), let location = headers["location"],
               let target = URL(string: location, relativeTo: url)?.absoluteURL {
                responseURL = target
                redirecting = true
                return
            }
            response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            if let response, stream.accepts(response) { stream.success?() }
        } else if readingHeaders, let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
    }

    private func milliseconds(_ interval: TimeInterval) -> Int64 {
        guard interval > 0, interval.isFinite else { return 0 }
        return Int64(min(interval * 1000, Double(Int32.max)))
    }

    private func proxySettings(
        _ configuration: URLSessionConfiguration, url: URL
    ) -> (address: String?, exceptions: String?) {
        guard let settings = configuration.connectionProxyDictionary else { return (nil, nil) }
        let prefix = url.scheme == "https" ? "HTTPS" : "HTTP"
        let exceptions = (settings["ExceptionsList"] as? [String])?.joined(separator: ",")
        if let enabled = settings[prefix + "Enable"] as? NSNumber, !enabled.boolValue {
            return ("", exceptions)
        }
        guard let host = settings[prefix + "Proxy"] as? String else { return (nil, exceptions) }
        var address = URLComponents()
        address.scheme = "http"
        address.host = host
        address.port = (settings[prefix + "Port"] as? NSNumber)?.intValue
        return (address.string, exceptions)
    }
}
#endif
