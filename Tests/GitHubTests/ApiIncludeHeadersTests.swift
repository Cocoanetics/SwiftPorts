#if !os(Android)  // depends on GhCommand; ArgumentParser trips the Android explicit-module scanner
import Foundation
import HTTPTypes
import Testing
@testable import GitHub
@testable import GhCommand

/// Pins the `gh api --include` preamble to upstream gh 2.89.0's
/// exact bytes (api.go `processResponse` + `printHeaders`), captured
/// live against api.github.com.
@Suite struct ApiIncludeHeadersTests {

    // MARK: Go canonical-MIME header names

    @Test func canonicalizesNamesLikeGoTextproto() {
        // gh prints Go's canonical form, not GitHub's own casing:
        // HTTP/2 lowercases names on the wire and Go re-capitalizes
        // the first letter and each letter after a hyphen.
        #expect(ApiCommand.canonicalHeaderName("x-ratelimit-limit") == "X-Ratelimit-Limit")
        #expect(ApiCommand.canonicalHeaderName("X-RateLimit-Limit") == "X-Ratelimit-Limit")
        #expect(ApiCommand.canonicalHeaderName("x-github-request-id") == "X-Github-Request-Id")
        #expect(ApiCommand.canonicalHeaderName("etag") == "Etag")
        #expect(ApiCommand.canonicalHeaderName("ETag") == "Etag")
        #expect(ApiCommand.canonicalHeaderName("content-type") == "Content-Type")
        #expect(ApiCommand.canonicalHeaderName("strict-transport-security")
            == "Strict-Transport-Security")
    }

    @Test func leavesNonTokenNamesUntouched() {
        // Go returns keys containing non-token bytes unmodified.
        #expect(ApiCommand.canonicalHeaderName("weird header") == "weird header")
        #expect(ApiCommand.canonicalHeaderName("weird:header") == "weird:header")
        #expect(ApiCommand.canonicalHeaderName("") == "")
    }

    // MARK: Go net/http StatusText

    @Test func statusTextMatchesGoTable() {
        #expect(ApiCommand.statusText(200) == "OK")
        #expect(ApiCommand.statusText(201) == "Created")
        #expect(ApiCommand.statusText(204) == "No Content")
        #expect(ApiCommand.statusText(304) == "Not Modified")
        #expect(ApiCommand.statusText(403) == "Forbidden")
        #expect(ApiCommand.statusText(404) == "Not Found")
        #expect(ApiCommand.statusText(422) == "Unprocessable Entity")
        #expect(ApiCommand.statusText(418) == "I'm a teapot")
        // Go kept the legacy RFC 2616 names for these, not the
        // modern RFC 9110 ones.
        #expect(ApiCommand.statusText(413) == "Request Entity Too Large")
        #expect(ApiCommand.statusText(414) == "Request URI Too Long")
        #expect(ApiCommand.statusText(416) == "Requested Range Not Satisfiable")
        #expect(ApiCommand.statusText(599) == "")
    }

    // MARK: --include preamble bytes

    @Test func rendersStatusLineHeadersAndBlankLine() {
        var fields = HTTPFields()
        fields[HTTPField.Name("content-type")!] = "application/json; charset=utf-8"
        fields[HTTPField.Name("x-ratelimit-limit")!] = "5000"
        fields[HTTPField.Name("server")!] = "github.com"
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/2.0", status: 200, headerFields: fields)
        // The status line ends \n; every header line and the closing
        // blank line end \r\n — gh writes exactly these bytes.
        #expect(out == "HTTP/2.0 200 OK\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Server: github.com\r\n"
            + "X-Ratelimit-Limit: 5000\r\n"
            + "\r\n")
    }

    @Test func sortsHeaderNamesASCIIbetically() {
        var fields = HTTPFields()
        fields[HTTPField.Name("x-frame-options")!] = "deny"
        fields[HTTPField.Name("vary")!] = "Accept"
        fields[HTTPField.Name("access-control-allow-origin")!] = "*"
        fields[HTTPField.Name("date")!] = "Fri, 12 Jun 2026 07:36:41 GMT"
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/2.0", status: 200, headerFields: fields)
        #expect(out == "HTTP/2.0 200 OK\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Date: Fri, 12 Jun 2026 07:36:41 GMT\r\n"
            + "Vary: Accept\r\n"
            + "X-Frame-Options: deny\r\n"
            + "\r\n")
    }

    @Test func skipsLegacyStatusHeader() {
        // printHeaders drops the header literally named `Status`
        // (GitHub used to send `Status: 200 OK`).
        var fields = HTTPFields()
        fields[HTTPField.Name("status")!] = "200 OK"
        fields[HTTPField.Name("server")!] = "github.com"
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/2.0", status: 200, headerFields: fields)
        #expect(out == "HTTP/2.0 200 OK\nServer: github.com\r\n\r\n")
    }

    @Test func joinsRepeatedFieldsWithCommaSpace() {
        var fields = HTTPFields()
        fields.append(HTTPField(name: HTTPField.Name("vary")!, value: "Accept"))
        fields.append(HTTPField(name: HTTPField.Name("vary")!, value: "Accept-Encoding"))
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/2.0", status: 200, headerFields: fields)
        #expect(out.contains("Vary: Accept, Accept-Encoding\r\n"))
    }

    @Test func unknownStatusKeepsGoTrailingSpace() {
        // Go synthesizes `Status = "<code> " + StatusText(code)`; for
        // unknown codes the text is empty and gh prints the trailing
        // space.
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/2.0", status: 599, headerFields: [:])
        #expect(out == "HTTP/2.0 599 \n\r\n")
    }

    @Test func statusLineShowsNegotiatedProtocol() {
        // A GitHub Enterprise host may only negotiate HTTP/1.1;
        // upstream prints the real `resp.Proto`, so the renderer
        // takes it as input rather than assuming h2.
        let out = ApiCommand.formatIncludeHeaders(proto: "HTTP/1.1", status: 200, headerFields: [:])
        #expect(out == "HTTP/1.1 200 OK\n\r\n")
    }

    @Test func protoTokenMapsALPNNamesToGoForm() {
        // URLSessionTaskMetrics reports ALPN-style names; gh prints
        // Go's resp.Proto tokens.
        #expect(APIClient.protoToken(fromNetworkProtocolName: "h2") == "HTTP/2.0")
        #expect(APIClient.protoToken(fromNetworkProtocolName: "h2c") == "HTTP/2.0")
        #expect(APIClient.protoToken(fromNetworkProtocolName: "http/1.1") == "HTTP/1.1")
        #expect(APIClient.protoToken(fromNetworkProtocolName: "http/1.0") == "HTTP/1.0")
        #expect(APIClient.protoToken(fromNetworkProtocolName: "h3") == "HTTP/3.0")
        #expect(APIClient.protoToken(fromNetworkProtocolName: "spdy/3") == nil)
        #expect(APIClient.protoToken(fromNetworkProtocolName: nil) == nil)
    }

    // MARK: transparent-decompression header scrub

    @Test func scrubsTransparentlyDecodedTransferHeaders() {
        // URLSession inflates the body but reports the original
        // Content-Encoding/Content-Length; Go deletes both when it
        // gunzips, and --include output reflects that.
        var fields = HTTPFields()
        fields[.contentEncoding] = "gzip"
        fields[.contentLength] = "1234"
        fields[.contentType] = "application/json"
        let out = APIClient.scrubbedHeaderFields(fields)
        #expect(out[.contentEncoding] == nil)
        #expect(out[.contentLength] == nil)
        #expect(out[.contentType] == "application/json")
    }

    @Test func keepsTransferHeadersForIdentityBodies() {
        var fields = HTTPFields()
        fields[.contentLength] = "537"
        fields[.contentType] = "application/json"
        let out = APIClient.scrubbedHeaderFields(fields)
        #expect(out[.contentLength] == "537")
        #expect(out[.contentType] == "application/json")
    }
}

#endif  // !os(Android)
