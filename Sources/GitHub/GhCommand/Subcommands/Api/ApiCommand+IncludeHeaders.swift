import Foundation
import HTTPTypes

// `gh api --include` preamble rendering, mirroring upstream gh's
// `processResponse` + `printHeaders` (pkg/cmd/api/api.go) byte for
// byte.
extension ApiCommand {

    /// Render the `--include` preamble: status line, every response
    /// header, and a blank separator line.
    ///
    /// Exactly the bytes upstream writes:
    /// - `<proto> <code> <text>\n`. Go's net/http synthesizes the
    ///   status for HTTP/2 responses as `"<code> " + StatusText(code)`
    ///   (the wire carries no reason phrase) and gh prints
    ///   `resp.Proto resp.Status`. `proto` is the negotiated
    ///   protocol in Go's form (`HTTP/2.0`, `HTTP/1.1`). Unknown
    ///   codes keep Go's trailing space (`HTTP/2.0 599 `).
    /// - one `Name: value\r\n` line per header — names in Go's
    ///   canonical-MIME form, ASCII-sorted, repeated fields joined
    ///   with ", ", the legacy `Status` header skipped.
    /// - a closing `\r\n`.
    static func formatIncludeHeaders(proto: String, status: Int, headerFields: HTTPFields) -> String {
        var grouped: [String: [String]] = [:]
        for field in headerFields {
            grouped[canonicalHeaderName(field.name.rawName), default: []].append(field.value)
        }
        grouped["Status"] = nil

        var out = "\(proto) \(status) \(statusText(status))\n"
        for name in grouped.keys.sorted() {
            out += "\(name): \(grouped[name]!.joined(separator: ", "))\r\n"
        }
        out += "\r\n"
        return out
    }

    /// Go `textproto.CanonicalMIMEHeaderKey`: the first letter and
    /// any letter following a hyphen is uppercased, every other
    /// letter lowercased — `x-ratelimit-limit` → `X-Ratelimit-Limit`
    /// (gh shows the Go form, NOT GitHub's own `X-RateLimit-Limit`
    /// casing). Names containing bytes outside the HTTP token set
    /// come back unchanged, like Go.
    static func canonicalHeaderName(_ name: String) -> String {
        guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else { return name }
        var out = String.UnicodeScalarView()
        var upper = true
        for byte in name.utf8 {
            var c = byte
            if upper, c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z") {
                c -= 0x20
            } else if !upper, c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") {
                c += 0x20
            }
            out.append(Unicode.Scalar(c))
            upper = c == UInt8(ascii: "-")
        }
        return String(out)
    }

    /// RFC 7230 token bytes, per Go textproto's `validHeaderFieldByte`.
    private static func isTokenByte(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"),
             UInt8(ascii: "%"), UInt8(ascii: "&"), UInt8(ascii: "'"),
             UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"),
             UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
             UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    /// Go `net/http.StatusText` verbatim — the status line shows Go's
    /// strings, including the legacy RFC 2616 names (413/414/416),
    /// and "" for unknown codes.
    static func statusText(_ code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 102: return "Processing"
        case 103: return "Early Hints"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 203: return "Non-Authoritative Information"
        case 204: return "No Content"
        case 205: return "Reset Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 208: return "Already Reported"
        case 226: return "IM Used"
        case 300: return "Multiple Choices"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 305: return "Use Proxy"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 407: return "Proxy Authentication Required"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 412: return "Precondition Failed"
        case 413: return "Request Entity Too Large"
        case 414: return "Request URI Too Long"
        case 415: return "Unsupported Media Type"
        case 416: return "Requested Range Not Satisfiable"
        case 417: return "Expectation Failed"
        case 418: return "I'm a teapot"
        case 421: return "Misdirected Request"
        case 422: return "Unprocessable Entity"
        case 423: return "Locked"
        case 424: return "Failed Dependency"
        case 425: return "Too Early"
        case 426: return "Upgrade Required"
        case 428: return "Precondition Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 451: return "Unavailable For Legal Reasons"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 505: return "HTTP Version Not Supported"
        case 506: return "Variant Also Negotiates"
        case 507: return "Insufficient Storage"
        case 508: return "Loop Detected"
        case 510: return "Not Extended"
        case 511: return "Network Authentication Required"
        default: return ""
        }
    }
}
